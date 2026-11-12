DROP FUNCTION IF EXISTS public.kk_student_rating(integer);

CREATE OR REPLACE FUNCTION public.kk_student_rating(p_direction_code text)
RETURNS TABLE (
    full_name varchar,
    snils varchar,
    priority integer,
    total_score bigint
)
LANGUAGE sql
STABLE
AS $$
    WITH direction_choices AS (
        SELECT DISTINCT ON (a.applicant_id)
               a.applicant_id, choice.priority, EXTRACT(YEAR FROM ac.start_date)::integer AS exam_year
        FROM public.student AS s
        JOIN public.application AS a ON a.applicant_id = s.applicant_id
        JOIN public.admission_campaign AS ac ON ac.admission_campaign_id = a.admission_campaign_id
        JOIN public.application_educational_program_priority AS choice
            ON choice.application_id = a.application_id
        JOIN public.educational_program AS ep
            ON ep.educational_program_id = choice.educational_program_id
        WHERE ep.direction_code = p_direction_code
          AND a.application_status <> 'CANCELLED'
        ORDER BY a.applicant_id, a.submission_date DESC, a.application_id DESC, choice.priority
    )
    SELECT person.full_name, person.snils, dc.priority, scores.total_score
    FROM direction_choices AS dc
    JOIN LATERAL (
        SELECT SUM(best.score) AS total_score
        FROM (
            SELECT MAX(er.score) AS score
            FROM public.exam_result AS er
            WHERE er.applicant_id = dc.applicant_id
              AND er.exam_year = dc.exam_year
            GROUP BY er.exam_type
        ) AS best
    ) AS scores ON scores.total_score IS NOT NULL
    LEFT JOIN LATERAL (
        SELECT p.full_name, pd.snils
        FROM public.personal_data AS pd
        LEFT JOIN public.passport AS p ON p.personal_data_id = pd.personal_data_id
        WHERE pd.applicant_id = dc.applicant_id
        ORDER BY (p.full_name IS NOT NULL) DESC, p.issue_date DESC NULLS LAST,
                 p.passport_id DESC NULLS LAST, pd.personal_data_id DESC
        LIMIT 1
    ) AS person ON true
    ORDER BY scores.total_score DESC, dc.priority, dc.applicant_id;
$$;

-- Пример: SELECT * FROM public.kk_student_rating('09.03.04');

-- 2. Сведения об обучении и оплате по номеру зачётки.

-- Список выходных полей PostgreSQL меняет через пересоздание функции.
DROP FUNCTION IF EXISTS public.kk_student_payment_report(text);
DROP FUNCTION IF EXISTS public.kk_student_enrollment_certificate(text);

CREATE FUNCTION public.kk_student_payment_report(p_record_book_number text)
RETURNS TABLE (
    full_name varchar,
    faculty_name varchar,
    study_year integer,
    "рейтинг по экзаменам" numeric,
    paid_amount numeric,
    remaining_to_pay numeric,
    last_paid_month text,
    debt_amount numeric
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_student_id bigint;
BEGIN
    v_student_id := (
        SELECT s.applicant_id
        FROM public.student AS s
        WHERE s.record_book_number = p_record_book_number
    );

    IF v_student_id IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH contracts AS (
        SELECT c.contract_id, c.amount, c.start_date, c.end_date, plan.periodicity
        FROM public.contract AS c
        LEFT JOIN LATERAL (
            SELECT p.periodicity
            FROM public.payment AS p
            WHERE p.contract_id = c.contract_id
              AND (p.payment_status = 'PENDING'
                   OR (p.payment_status = 'PAID' AND p.payment_date <= CURRENT_DATE))
            ORDER BY p.payment_date DESC, p.payment_id DESC
            LIMIT 1
        ) AS plan ON true
        WHERE c.student_id = v_student_id
          AND c.conclusion_date <= CURRENT_DATE
    ),
    receipts AS (
        SELECT c.contract_id, COALESCE(SUM(p.amount), 0) AS paid_total,
               MAX(p.payment_date) AS last_paid_on
        FROM contracts AS c
        LEFT JOIN public.payment AS p
            ON p.contract_id = c.contract_id
           AND p.payment_status = 'PAID'
           AND p.payment_date <= CURRENT_DATE
        GROUP BY c.contract_id
    ),
    due_dates AS (
        SELECT c.contract_id, c.end_date,
               CASE WHEN c.periodicity = 'YEARLY'
                    THEN (c.start_date + make_interval(years => ((m.month_no - 1) / 12)::int))::date
                    ELSE GREATEST(c.start_date, m.month_start::date)
               END AS due_on
        FROM contracts AS c
        CROSS JOIN LATERAL generate_series(
            date_trunc('month', c.start_date::timestamp),
            date_trunc('month', c.end_date::timestamp),
            interval '1 month'
        ) WITH ORDINALITY AS m(month_start, month_no)
        WHERE c.end_date >= c.start_date
          AND (c.periodicity = 'MONTHLY'
            OR (c.periodicity = 'SEMESTER'
                AND (m.month_no = 1 OR EXTRACT(MONTH FROM m.month_start) IN (2, 9)))
            OR (c.periodicity = 'YEARLY' AND (m.month_no - 1) % 12 = 0))
    ),
    periods AS (
        SELECT d.contract_id, d.due_on,
               LEAD(d.due_on, 1, d.end_date + 1) OVER (
                   PARTITION BY d.contract_id ORDER BY d.due_on
               ) AS next_due_on
        FROM due_dates AS d
        WHERE d.due_on <= d.end_date
    ),
    period_amounts AS (
        -- В графике есть и уже наступившие периоды без записей об оплате.
        SELECT d.contract_id, d.due_on, SUM(p.amount) AS recorded_amount
        FROM periods AS d
        JOIN contracts AS c USING (contract_id)
        LEFT JOIN public.payment AS p
            ON p.contract_id = d.contract_id
           AND p.periodicity = c.periodicity
           AND p.payment_date >= d.due_on
           AND p.payment_date < d.next_due_on
           AND p.amount > 0
           AND (p.payment_status = 'PENDING'
                OR (p.payment_status = 'PAID' AND p.payment_date <= CURRENT_DATE))
        GROUP BY d.contract_id, d.due_on
    ),
    installments AS (
        SELECT p.contract_id, COUNT(*) AS period_count,
               COUNT(*) FILTER (WHERE p.due_on <= CURRENT_DATE) AS due_count,
               MODE() WITHIN GROUP (ORDER BY p.recorded_amount DESC) AS typical_amount
        FROM period_amounts AS p
        GROUP BY p.contract_id
    ),
    balances AS (
        SELECT
            r.paid_total,
            r.last_paid_on,
            GREATEST(c.amount - r.paid_total, 0) AS remaining_amount,
            CASE
                WHEN c.start_date > CURRENT_DATE OR r.paid_total >= c.amount THEN 0
                WHEN i.period_count IS NULL THEN NULL
                WHEN i.due_count = i.period_count THEN GREATEST(c.amount - r.paid_total, 0)
                ELSE GREATEST(LEAST(c.amount, ROUND(i.due_count * COALESCE(
                    i.typical_amount, c.amount / i.period_count
                ), 2)) - r.paid_total, 0)
            END AS overdue_amount
        FROM contracts AS c
        JOIN receipts AS r USING (contract_id)
        LEFT JOIN installments AS i USING (contract_id)
    ),
    payment_totals AS (
        SELECT COALESCE(SUM(b.paid_total), 0) AS paid_total,
               COALESCE(SUM(b.remaining_amount), 0) AS remaining_amount,
               MAX(b.last_paid_on) AS last_paid_on,
               CASE WHEN BOOL_OR(b.overdue_amount IS NULL) THEN NULL
                    ELSE COALESCE(SUM(b.overdue_amount), 0)
               END AS overdue_amount
        FROM balances AS b
    )
    SELECT
        (
            SELECT p.full_name
            FROM public.personal_data AS pd
            JOIN public.passport AS p ON p.personal_data_id = pd.personal_data_id
            WHERE pd.applicant_id = v_student_id
              AND p.full_name IS NOT NULL
            ORDER BY p.issue_date DESC NULLS LAST, p.passport_id DESC
            LIMIT 1
        ),
        study.faculty_name,
        study.course,
        (
            SELECT ROUND(AVG(er.score), 2)
            FROM public.exam_result AS er
            WHERE er.applicant_id = v_student_id
        ),
        totals.paid_total,
        totals.remaining_amount,
        to_char(totals.last_paid_on, 'YYYY-MM'),
        totals.overdue_amount
    FROM payment_totals AS totals
    LEFT JOIN LATERAL (
        SELECT f.faculty_name, sg.course
        FROM public.student_study_group AS ssg
        JOIN public.study_group AS sg ON sg.study_group_id = ssg.study_group_id
        JOIN public.specialty AS sp ON sp.specialty_id = sg.specialty_id
        JOIN public.faculty AS f ON f.faculty_id = sp.faculty_id
        WHERE ssg.student_id = v_student_id
        ORDER BY sg.admission_year DESC, sg.study_group_id DESC
        LIMIT 1
    ) AS study ON true;
END;
$$;

-- Пример: SELECT * FROM public.kk_student_payment_report('48371625');
