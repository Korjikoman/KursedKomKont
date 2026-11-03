
BEGIN;
SET LOCAL search_path = pg_catalog, public;
SET LOCAL lock_timeout = '5s';

DO $check_base$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['student','applicant','application','admission_campaign',
        'educational_program','specialty','exam_result','passport','personal_data',
        'contract','payment'] LOOP
        IF to_regclass(format('public.%I', t)) IS NULL THEN
            RAISE EXCEPTION 'Не найдена public.%. Сначала установите базовую модель.', t;
        END IF;
    END LOOP;
END;
$check_base$;

DO $periodicity$
BEGIN
    IF to_regtype('public.payment_periodicity') IS NULL THEN
        CREATE TYPE public.payment_periodicity AS ENUM ('MONTHLY', 'SEMESTER', 'YEARLY');
    ELSIF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
           FROM pg_enum e WHERE e.enumtypid = 'public.payment_periodicity'::regtype)
          IS DISTINCT FROM ARRAY['MONTHLY', 'SEMESTER', 'YEARLY']::text[] THEN
        RAISE EXCEPTION 'Существующий тип payment_periodicity имеет другой состав значений.';
    END IF;
END;
$periodicity$;

ALTER TABLE public.payment ADD COLUMN IF NOT EXISTS periodicity public.payment_periodicity;
COMMENT ON COLUMN public.payment.periodicity IS
    'Периодичность: MONTHLY — раз в месяц; SEMESTER — раз в семестр; YEARLY — раз в год. NULL — не указано.';

CREATE TABLE IF NOT EXISTS public.direction_choice (
    direction_choice_id bigserial PRIMARY KEY,
    applicant_id bigint NOT NULL REFERENCES public.applicant(applicant_id) ON DELETE CASCADE,
    educational_program_id bigint NOT NULL
        REFERENCES public.educational_program(educational_program_id) ON DELETE RESTRICT,
    admission_campaign_id bigint NOT NULL
        REFERENCES public.admission_campaign(admission_campaign_id) ON DELETE RESTRICT,
    priority integer NOT NULL CHECK (priority > 0),
    UNIQUE (applicant_id, admission_campaign_id, educational_program_id),
    UNIQUE (applicant_id, admission_campaign_id, priority)
);
COMMENT ON TABLE public.direction_choice IS
    'Выбор направления (выбор приоритета): связь M:N абитуриентов и образовательных программ в рамках кампании.';
COMMENT ON COLUMN public.direction_choice.priority IS 'Приоритет: 1 — наивысший.';
CREATE INDEX IF NOT EXISTS ix_direction_choice_program_campaign
    ON public.direction_choice(educational_program_id, admission_campaign_id, priority);

-- Защита номера нового заявления в пределах кампании; данные не удаляются.
CREATE UNIQUE INDEX IF NOT EXISTS ux_kk_application_campaign_number
    ON public.application(admission_campaign_id, application_number);

-- Необходимые зависимости исходных триггеров и финансовых функций ниже.


CREATE TABLE IF NOT EXISTS public.application_state (
    application_id bigint PRIMARY KEY
        REFERENCES public.application(application_id) ON DELETE CASCADE,
    workflow_status varchar(30) NOT NULL DEFAULT 'NEW'
        CHECK (workflow_status IN (
            'NEW', 'SUBMITTED', 'NEEDS_FIX', 'ADMITTED',
            'RECOMMENDED', 'ENROLLED', 'REJECTED'
        )),
    review_remarks text,
    reviewed_by varchar(100),
    reviewed_at timestamp,
    updated_at timestamp NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.payment_schedule (
    payment_schedule_id bigserial PRIMARY KEY,
    contract_id bigint NOT NULL
        REFERENCES public.contract(contract_id) ON DELETE CASCADE,
    installment_no integer NOT NULL CHECK (installment_no > 0),
    period_start date NOT NULL,
    period_end date NOT NULL,
    due_date date NOT NULL,
    amount numeric(12,2) NOT NULL CHECK (amount >= 0),
    penalty_rate numeric(10,6) NOT NULL DEFAULT 0.001
        CHECK (penalty_rate >= 0),
    UNIQUE (contract_id, installment_no)
);

CREATE TABLE IF NOT EXISTS public.payment_allocation (
    payment_id bigint NOT NULL
        REFERENCES public.payment(payment_id) ON DELETE CASCADE,
    payment_schedule_id bigint NOT NULL
        REFERENCES public.payment_schedule(payment_schedule_id) ON DELETE CASCADE,
    amount numeric(12,2) NOT NULL CHECK (amount > 0),
    PRIMARY KEY (payment_id, payment_schedule_id)
);

CREATE TABLE IF NOT EXISTS public.audit_log (
    audit_id bigserial PRIMARY KEY,
    table_name varchar(100) NOT NULL,
    operation varchar(10) NOT NULL,
    record_key text,
    old_data jsonb,
    new_data jsonb,
    changed_by varchar(100) NOT NULL DEFAULT current_user,
    changed_at timestamp NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_payment_schedule_contract_due ON public.payment_schedule(contract_id, due_date);

CREATE INDEX IF NOT EXISTS ix_payment_allocation_schedule ON public.payment_allocation(payment_schedule_id);

-- ============================================================
-- 12 ФУНКЦИЙ. Номера соответствуют списку в задании.
-- Финансовые функции идут первыми из-за зависимостей.
-- ============================================================

-- 7. Долг по конкретному периоду оплаты, включая ещё не наступивший срок.
CREATE OR REPLACE FUNCTION public.kk_period_debt(
    p_payment_schedule_id bigint, p_as_of date DEFAULT CURRENT_DATE
)
RETURNS numeric LANGUAGE sql STABLE STRICT
AS $$
    SELECT GREATEST(s.amount - COALESCE((
        SELECT SUM(a.amount) FROM public.payment_allocation a
        JOIN public.payment p ON p.payment_id = a.payment_id
        WHERE a.payment_schedule_id = s.payment_schedule_id
          AND p.payment_status = 'PAID' AND p.payment_date <= p_as_of
    ), 0), 0)
    FROM public.payment_schedule s
    WHERE s.payment_schedule_id = p_payment_schedule_id;
$$;

-- 8. Просроченный долг по периоду. В день срока оплаты просрочки ещё нет.
CREATE OR REPLACE FUNCTION public.kk_period_overdue_debt(
    p_payment_schedule_id bigint, p_as_of date DEFAULT CURRENT_DATE
)
RETURNS numeric LANGUAGE sql STABLE STRICT
AS $$
    SELECT CASE WHEN s.due_date < p_as_of
                THEN public.kk_period_debt(s.payment_schedule_id, p_as_of)
                ELSE 0::numeric END
    FROM public.payment_schedule s
    WHERE s.payment_schedule_id = p_payment_schedule_id;
$$;

-- 9. Общая сумма всех начислений графика договора, включая будущие периоды.
CREATE OR REPLACE FUNCTION public.kk_contract_accrued(p_contract_id bigint)
RETURNS numeric LANGUAGE sql STABLE STRICT
AS $$
    SELECT COALESCE((SELECT SUM(s.amount) FROM public.payment_schedule s
                     WHERE s.contract_id = c.contract_id), 0)
    FROM public.contract c WHERE c.contract_id = p_contract_id;
$$;

-- 10. Общая сумма подтверждённых оплат, распределённых на договор.
CREATE OR REPLACE FUNCTION public.kk_contract_paid(
    p_contract_id bigint, p_as_of date DEFAULT CURRENT_DATE
)
RETURNS numeric LANGUAGE sql STABLE STRICT
AS $$
    SELECT COALESCE((
        SELECT SUM(a.amount) FROM public.payment_allocation a
        JOIN public.payment_schedule s ON s.payment_schedule_id = a.payment_schedule_id
        JOIN public.payment p ON p.payment_id = a.payment_id
        WHERE s.contract_id = c.contract_id
          AND p.payment_status = 'PAID' AND p.payment_date <= p_as_of
    ), 0)
    FROM public.contract c WHERE c.contract_id = p_contract_id;
$$;

-- 11. Текущий долг договора: только периоды с наступившим сроком оплаты.
CREATE OR REPLACE FUNCTION public.kk_contract_debt(
    p_contract_id bigint, p_as_of date DEFAULT CURRENT_DATE
)
RETURNS numeric LANGUAGE sql STABLE STRICT
AS $$
    SELECT COALESCE((
        SELECT SUM(public.kk_period_debt(s.payment_schedule_id, p_as_of))
        FROM public.payment_schedule s
        WHERE s.contract_id = c.contract_id AND s.due_date <= p_as_of
    ), 0)
    FROM public.contract c WHERE c.contract_id = p_contract_id;
$$;

-- 1. Студенты, не оплатившие начисления со сроком оплаты в выбранном семестре.
CREATE OR REPLACE FUNCTION public.kk_students_unpaid_semester(
    p_semester_start date, p_semester_end date,
    p_as_of date DEFAULT CURRENT_DATE, p_educational_program_id bigint DEFAULT NULL
)
RETURNS TABLE (
    student_id bigint, applicant_id bigint, full_name text,
    contract_id bigint, contract_number varchar,
    semester_accrued numeric, semester_paid numeric, debt numeric,
    overdue_debt numeric, phone varchar, email varchar
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF p_semester_start IS NULL OR p_semester_end IS NULL OR p_as_of IS NULL
       OR p_semester_start > p_semester_end THEN
        RAISE EXCEPTION 'Укажите корректные границы семестра и дату расчёта.';
    END IF;
    RETURN QUERY
    SELECT st.student_id, st.applicant_id,
           COALESCE(NULLIF(concat_ws(' ', ps.surname, ps.name, ps.otchestvo), ''),
                    'Студент #' || st.student_id::text),
           c.contract_id, c.contract_number,
           x.accrued, x.accrued - x.balance, x.balance, x.overdue,
           ap.phone, ap.email
    FROM public.student st
    JOIN public.contract c ON c.student_id = st.student_id
    LEFT JOIN public.applicant ap ON ap.applicant_id = st.applicant_id
    LEFT JOIN LATERAL (
        SELECT pp.surname, pp.name, pp.otchestvo FROM public.passport pp
        WHERE pp.applicant_id = st.applicant_id
        ORDER BY pp.issue_date DESC, pp.passport_id DESC, pp.personal_data_id DESC LIMIT 1
    ) ps ON true
    CROSS JOIN LATERAL (
        SELECT COALESCE(SUM(s.amount), 0) AS accrued,
               COALESCE(SUM(public.kk_period_debt(s.payment_schedule_id, p_as_of)), 0) AS balance,
               COALESCE(SUM(public.kk_period_overdue_debt(s.payment_schedule_id, p_as_of)), 0) AS overdue
        FROM public.payment_schedule s
        WHERE s.contract_id = c.contract_id
          AND s.due_date BETWEEN p_semester_start AND p_semester_end
          AND s.due_date <= p_as_of
    ) x
    WHERE x.balance > 0
      AND (p_educational_program_id IS NULL OR c.educational_program_id = p_educational_program_id)
    ORDER BY x.balance DESC, st.student_id, c.contract_id;
END;
$$;

-- 2. Студенты с недостающими паспортом, СНИЛС или результатами испытаний.
CREATE OR REPLACE FUNCTION public.kk_students_missing_documents(p_exam_year integer DEFAULT NULL)
RETURNS TABLE (
    student_id bigint, applicant_id bigint, full_name text,
    missing_passport boolean, missing_snils boolean, missing_exam_results boolean,
    missing_documents text[], phone varchar, email varchar
)
LANGUAGE sql STABLE AS $$
    SELECT st.student_id, st.applicant_id,
           COALESCE(NULLIF(concat_ws(' ', ps.surname, ps.name, ps.otchestvo), ''),
                    'Студент #' || st.student_id::text),
           NOT d.has_passport, NOT d.has_snils, NOT d.has_exams,
           array_remove(ARRAY[
               CASE WHEN NOT d.has_passport THEN 'Паспорт'::text END,
               CASE WHEN NOT d.has_snils THEN 'СНИЛС'::text END,
               CASE WHEN NOT d.has_exams THEN 'Результаты испытаний'::text END
           ], NULL), ap.phone, ap.email
    FROM public.student st
    LEFT JOIN public.applicant ap ON ap.applicant_id = st.applicant_id
    LEFT JOIN LATERAL (
        SELECT pp.surname, pp.name, pp.otchestvo FROM public.passport pp
        WHERE pp.applicant_id = st.applicant_id
        ORDER BY pp.issue_date DESC, pp.passport_id DESC, pp.personal_data_id DESC LIMIT 1
    ) ps ON true
    CROSS JOIN LATERAL (
        SELECT EXISTS (SELECT 1 FROM public.passport pp
                       WHERE pp.applicant_id = st.applicant_id
                         AND btrim(pp.passport_number) <> '' AND btrim(pp.series) <> '') AS has_passport,
               EXISTS (SELECT 1 FROM public.personal_data pd
                       WHERE pd.applicant_id = st.applicant_id AND btrim(pd.snils) <> '') AS has_snils,
               EXISTS (SELECT 1 FROM public.exam_result er
                       WHERE er.applicant_id = st.applicant_id AND er.score BETWEEN 0 AND 100
                         AND btrim(er.exam_type) <> ''
                         AND (p_exam_year IS NULL OR er.exam_year = p_exam_year)) AS has_exams
    ) d
    WHERE NOT d.has_passport OR NOT d.has_snils OR NOT d.has_exams
    ORDER BY st.student_id;
$$;

-- 3. Общая сумма фактически полученных денег с платников за интервал дат.
CREATE OR REPLACE FUNCTION public.kk_paid_tuition_total(
    p_date_from date DEFAULT NULL, p_date_to date DEFAULT NULL
)
RETURNS numeric LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF p_date_from > p_date_to THEN RAISE EXCEPTION 'Начало периода позже конца.'; END IF;
    RETURN (SELECT COALESCE(SUM(p.amount), 0) FROM public.payment p
            WHERE p.payment_status = 'PAID'
              AND (p_date_from IS NULL OR p.payment_date >= p_date_from)
              AND (p_date_to IS NULL OR p.payment_date <= p_date_to));
END;
$$;

-- 4. Прогноз поступления на специальность по баллам, местам и приоритету.
CREATE OR REPLACE FUNCTION public.kk_specialty_admission_list(
    p_specialty_id bigint, p_min_total_score integer, p_free_places integer,
    p_priority integer, p_admission_campaign_id bigint DEFAULT NULL,
    p_exam_year integer DEFAULT NULL
)
RETURNS TABLE (
    rank_no bigint, applicant_id bigint, full_name text, specialty_id bigint,
    educational_program_id bigint, program_name varchar,
    total_score bigint, priority integer, phone varchar, email varchar
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF p_min_total_score IS NULL OR p_min_total_score < 0
       OR p_free_places IS NULL OR p_free_places < 0
       OR (p_priority IS NOT NULL AND p_priority <= 0) THEN
        RAISE EXCEPTION 'Баллы и число мест должны быть >= 0, приоритет > 0 либо NULL.';
    END IF;
    IF p_specialty_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.specialty sp WHERE sp.specialty_id = p_specialty_id
    ) THEN RAISE EXCEPTION 'Специальность % не найдена.', p_specialty_id; END IF;
    IF p_admission_campaign_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.admission_campaign ac WHERE ac.admission_campaign_id = p_admission_campaign_id
    ) THEN RAISE EXCEPTION 'Приёмная кампания % не найдена.', p_admission_campaign_id; END IF;
    RETURN QUERY
    WITH eligible AS (
        SELECT dc.applicant_id, ep.specialty_id, ep.educational_program_id,
               ep.program_name, dc.priority, ex.score, sub.submitted
        FROM public.direction_choice dc
        JOIN public.educational_program ep ON ep.educational_program_id = dc.educational_program_id
        JOIN public.admission_campaign ac ON ac.admission_campaign_id = dc.admission_campaign_id
        CROSS JOIN LATERAL (
            SELECT SUM(best.score)::bigint AS score FROM (
                SELECT MAX(er.score) AS score FROM public.exam_result er
                WHERE er.applicant_id = dc.applicant_id
                  AND er.exam_year = COALESCE(p_exam_year, ac.academic_year)
                GROUP BY er.exam_type
            ) best
        ) ex
        CROSS JOIN LATERAL (
            SELECT MIN(a.submission_date) AS submitted FROM public.application a
            LEFT JOIN public.application_state ast ON ast.application_id = a.application_id
            WHERE a.applicant_id = dc.applicant_id
              AND a.admission_campaign_id = dc.admission_campaign_id
              AND a.application_status <> 'CANCELLED'
              AND COALESCE(ast.workflow_status, 'NEW') <> 'REJECTED'
        ) sub
        WHERE ep.specialty_id = p_specialty_id
          AND ex.score >= p_min_total_score AND sub.submitted IS NOT NULL
          AND (p_priority IS NULL OR dc.priority = p_priority)
          AND (p_admission_campaign_id IS NULL OR dc.admission_campaign_id = p_admission_campaign_id)
    ), one_per_applicant AS (
        SELECT DISTINCT ON (e.applicant_id) e.* FROM eligible e
        ORDER BY e.applicant_id, e.score DESC, e.priority, e.submitted, e.educational_program_id
    ), ranked AS (
        SELECT ROW_NUMBER() OVER (ORDER BY e.score DESC, e.priority, e.submitted, e.applicant_id) AS rn, e.*
        FROM one_per_applicant e
    )
    SELECT r.rn, r.applicant_id,
           COALESCE(NULLIF(concat_ws(' ', ps.surname, ps.name, ps.otchestvo), ''),
                    'Абитуриент #' || r.applicant_id::text),
           r.specialty_id, r.educational_program_id, r.program_name,
           r.score, r.priority, ap.phone, ap.email
    FROM ranked r
    JOIN public.applicant ap ON ap.applicant_id = r.applicant_id
    LEFT JOIN LATERAL (
        SELECT pp.surname, pp.name, pp.otchestvo FROM public.passport pp
        WHERE pp.applicant_id = r.applicant_id
        ORDER BY pp.issue_date DESC, pp.passport_id DESC, pp.personal_data_id DESC LIMIT 1
    ) ps ON true
    ORDER BY r.rn LIMIT p_free_places;
END;
$$;

-- 5. Список должников. Одна строка на договор; будущие счета не образуют долг.
CREATE OR REPLACE FUNCTION public.kk_debtors(
    p_as_of date DEFAULT CURRENT_DATE, p_educational_program_id bigint DEFAULT NULL
)
RETURNS TABLE (
    student_id bigint, applicant_id bigint, full_name text,
    contract_id bigint, contract_number varchar,
    accrued_total numeric, paid_total numeric, current_debt numeric,
    overdue_debt numeric, phone varchar, email varchar
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF p_as_of IS NULL THEN RAISE EXCEPTION 'Укажите дату расчёта.'; END IF;
    RETURN QUERY
    SELECT c.student_id, st.applicant_id,
           COALESCE(NULLIF(concat_ws(' ', ps.surname, ps.name, ps.otchestvo), ''),
                    'Договор ' || c.contract_number::text),
           c.contract_id, c.contract_number,
           public.kk_contract_accrued(c.contract_id),
           public.kk_contract_paid(c.contract_id, p_as_of),
           x.balance, x.overdue, ap.phone, ap.email
    FROM public.contract c
    LEFT JOIN public.student st ON st.student_id = c.student_id
    LEFT JOIN public.applicant ap ON ap.applicant_id = st.applicant_id
    LEFT JOIN LATERAL (
        SELECT pp.surname, pp.name, pp.otchestvo FROM public.passport pp
        WHERE pp.applicant_id = st.applicant_id
        ORDER BY pp.issue_date DESC, pp.passport_id DESC, pp.personal_data_id DESC LIMIT 1
    ) ps ON true
    CROSS JOIN LATERAL (
        SELECT public.kk_contract_debt(c.contract_id, p_as_of) AS balance,
               COALESCE((SELECT SUM(public.kk_period_overdue_debt(s.payment_schedule_id, p_as_of))
                         FROM public.payment_schedule s WHERE s.contract_id = c.contract_id), 0) AS overdue
    ) x
    WHERE x.balance > 0
      AND (p_educational_program_id IS NULL OR c.educational_program_id = p_educational_program_id)
    ORDER BY x.overdue DESC, x.balance DESC, c.contract_id;
END;
$$;

-- 6. Создать новое заявление и состояние NEW; вернуть ID заявления.
CREATE OR REPLACE FUNCTION public.kk_create_application(
    p_applicant_id bigint, p_admission_campaign_id bigint,
    p_application_number varchar, p_submission_date date DEFAULT CURRENT_DATE
)
RETURNS bigint LANGUAGE plpgsql VOLATILE AS $$
DECLARE v_id bigint;
BEGIN
    IF p_applicant_id IS NULL OR p_admission_campaign_id IS NULL OR p_submission_date IS NULL
       OR p_application_number IS NULL OR btrim(p_application_number) = ''
       OR length(btrim(p_application_number)) > 50 THEN
        RAISE EXCEPTION 'Укажите абитуриента, кампанию, дату и номер заявления (1..50 символов).';
    END IF;
    INSERT INTO public.application(application_number, submission_date, application_status,
                                   admission_campaign_id, applicant_id)
    VALUES (btrim(p_application_number), p_submission_date, 'PROCESSED',
            p_admission_campaign_id, p_applicant_id)
    RETURNING application_id INTO v_id;
    INSERT INTO public.application_state(application_id, workflow_status) VALUES (v_id, 'NEW');
    RETURN v_id;
END;
$$;

-- 12. Топ специальностей по количеству и приоритетам выборов.
CREATE OR REPLACE FUNCTION public.kk_top_specialties(
    p_top_count integer, p_admission_campaign_id bigint DEFAULT NULL
)
RETURNS TABLE (
    rank_no bigint, specialty_id bigint, specialty_code varchar,
    applicants_count bigint, first_priority_count bigint, priority_score numeric
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF p_top_count IS NULL OR p_top_count < 0 THEN
        RAISE EXCEPTION 'Количество мест в топе должно быть >= 0.';
    END IF;
    RETURN QUERY
    WITH votes AS (
        SELECT ep.specialty_id, dc.applicant_id, MIN(dc.priority) AS best_priority
        FROM public.direction_choice dc
        JOIN public.educational_program ep ON ep.educational_program_id = dc.educational_program_id
        WHERE ep.specialty_id IS NOT NULL
          AND (p_admission_campaign_id IS NULL OR dc.admission_campaign_id = p_admission_campaign_id)
        GROUP BY ep.specialty_id, dc.applicant_id
    ), totals AS (
        SELECT v.specialty_id, COUNT(*) AS applicants,
               COUNT(*) FILTER (WHERE v.best_priority = 1) AS first_choices,
               SUM(1.0 / v.best_priority) AS score
        FROM votes v GROUP BY v.specialty_id
    )
    SELECT ROW_NUMBER() OVER (ORDER BY t.score DESC, t.first_choices DESC, t.applicants DESC, t.specialty_id),
           sp.specialty_id, sp.specialty_code, t.applicants, t.first_choices, ROUND(t.score, 6)
    FROM totals t JOIN public.specialty sp ON sp.specialty_id = t.specialty_id
    ORDER BY t.score DESC, t.first_choices DESC, t.applicants DESC, t.specialty_id
    LIMIT p_top_count;
END;
$$;


-- Исходные триггеры и их обслуживающие функции.
-- 35. Trigger function: validate admission campaign dates.
CREATE OR REPLACE FUNCTION public.trgfn_validate_campaign_dates()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.start_date > NEW.end_date THEN
        RAISE EXCEPTION 'Admission campaign start_date cannot be after end_date';
    END IF;

    IF NEW.academic_year < 2000 OR NEW.academic_year > 2200 THEN
        RAISE EXCEPTION 'Academic year % is outside the allowed range', NEW.academic_year;
    END IF;

    RETURN NEW;
END;
$$;

-- 36. Trigger: campaign validation.
DROP TRIGGER IF EXISTS trg_validate_campaign_dates ON public.admission_campaign;
CREATE TRIGGER trg_validate_campaign_dates
BEFORE INSERT OR UPDATE ON public.admission_campaign
FOR EACH ROW
EXECUTE FUNCTION public.trgfn_validate_campaign_dates();

-- 37. Trigger function: application submission date must belong to the campaign.
CREATE OR REPLACE FUNCTION public.trgfn_validate_application_submission_date()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_start date;
    v_end date;
BEGIN
    IF NEW.admission_campaign_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT start_date, end_date
    INTO v_start, v_end
    FROM public.admission_campaign
    WHERE admission_campaign_id = NEW.admission_campaign_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Admission campaign % does not exist', NEW.admission_campaign_id;
    END IF;

    IF NEW.submission_date < v_start OR NEW.submission_date > v_end THEN
        RAISE EXCEPTION
            'Submission date % is outside admission campaign interval [% - %]',
            NEW.submission_date, v_start, v_end;
    END IF;

    RETURN NEW;
END;
$$;

-- 38. Trigger: application date validation.
DROP TRIGGER IF EXISTS trg_validate_application_submission_date ON public.application;
CREATE TRIGGER trg_validate_application_submission_date
BEFORE INSERT OR UPDATE OF submission_date, admission_campaign_id
ON public.application
FOR EACH ROW
EXECUTE FUNCTION public.trgfn_validate_application_submission_date();

-- 39. Trigger function: exam score validation.
CREATE OR REPLACE FUNCTION public.trgfn_validate_exam_score()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.score < 0 OR NEW.score > 100 THEN
        RAISE EXCEPTION 'Exam score must be between 0 and 100';
    END IF;

    IF NEW.exam_year < 2000 OR NEW.exam_year > EXTRACT(YEAR FROM CURRENT_DATE)::integer + 1 THEN
        RAISE EXCEPTION 'Exam year % is invalid', NEW.exam_year;
    END IF;

    RETURN NEW;
END;
$$;

-- 40. Trigger: exam score validation.
DROP TRIGGER IF EXISTS trg_validate_exam_score ON public.exam_result;
CREATE TRIGGER trg_validate_exam_score
BEFORE INSERT OR UPDATE ON public.exam_result
FOR EACH ROW
EXECUTE FUNCTION public.trgfn_validate_exam_score();

-- 41. Trigger function: contract integrity validation.
CREATE OR REPLACE FUNCTION public.trgfn_validate_contract()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.amount <= 0 THEN
        RAISE EXCEPTION 'Contract amount must be positive';
    END IF;

    IF NEW.start_date > NEW.end_date THEN
        RAISE EXCEPTION 'Contract start_date cannot be after end_date';
    END IF;

    IF NEW.conclusion_date > NEW.end_date THEN
        RAISE EXCEPTION 'Contract conclusion_date cannot be after end_date';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.contract c
        WHERE c.contract_number = NEW.contract_number
          AND c.contract_id <> COALESCE(NEW.contract_id, -1)
    ) THEN
        RAISE EXCEPTION 'Contract number % must be unique', NEW.contract_number;
    END IF;

    RETURN NEW;
END;
$$;

-- 42. Trigger: contract validation.
DROP TRIGGER IF EXISTS trg_validate_contract ON public.contract;
CREATE TRIGGER trg_validate_contract
BEFORE INSERT OR UPDATE ON public.contract
FOR EACH ROW
EXECUTE FUNCTION public.trgfn_validate_contract();

-- 43. Trigger function: payment validation.
CREATE OR REPLACE FUNCTION public.trgfn_validate_payment()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be positive';
    END IF;

    IF NEW.payment_date > CURRENT_DATE + 1 THEN
        RAISE EXCEPTION 'Payment date % cannot be in the distant future', NEW.payment_date;
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.payment_allocation a
        WHERE a.payment_id = NEW.payment_id
        GROUP BY a.payment_id HAVING SUM(a.amount) > NEW.amount
    ) THEN
        RAISE EXCEPTION 'Сумма платежа меньше уже распределённой суммы.';
    END IF;

    RETURN NEW;
END;
$$;

-- 44. Trigger: payment validation.
DROP TRIGGER IF EXISTS trg_validate_payment ON public.payment;
CREATE TRIGGER trg_validate_payment
BEFORE INSERT OR UPDATE ON public.payment
FOR EACH ROW
EXECUTE FUNCTION public.trgfn_validate_payment();

-- 45. Generic trigger function for audit logging.
CREATE OR REPLACE FUNCTION public.trgfn_audit_row()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_key text;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_key := COALESCE(
            to_jsonb(NEW)->>'application_id',
            to_jsonb(NEW)->>'contract_id',
            to_jsonb(NEW)->>'payment_id',
            to_jsonb(NEW)->>'application_document_id',
            '?'
        );

        INSERT INTO public.audit_log(
            table_name,
            operation,
            record_key,
            old_data,
            new_data
        )
        VALUES (
            TG_TABLE_NAME,
            TG_OP,
            v_key,
            NULL,
            to_jsonb(NEW)
        );

        RETURN NEW;

    ELSIF TG_OP = 'UPDATE' THEN
        v_key := COALESCE(
            to_jsonb(NEW)->>'application_id',
            to_jsonb(NEW)->>'contract_id',
            to_jsonb(NEW)->>'payment_id',
            to_jsonb(NEW)->>'application_document_id',
            '?'
        );

        INSERT INTO public.audit_log(
            table_name,
            operation,
            record_key,
            old_data,
            new_data
        )
        VALUES (
            TG_TABLE_NAME,
            TG_OP,
            v_key,
            to_jsonb(OLD),
            to_jsonb(NEW)
        );

        RETURN NEW;

    ELSE
        v_key := COALESCE(
            to_jsonb(OLD)->>'application_id',
            to_jsonb(OLD)->>'contract_id',
            to_jsonb(OLD)->>'payment_id',
            to_jsonb(OLD)->>'application_document_id',
            '?'
        );

        INSERT INTO public.audit_log(
            table_name,
            operation,
            record_key,
            old_data,
            new_data
        )
        VALUES (
            TG_TABLE_NAME,
            TG_OP,
            v_key,
            to_jsonb(OLD),
            NULL
        );

        RETURN OLD;
    END IF;
END;
$$;

-- 46. Audit application changes.
DROP TRIGGER IF EXISTS trg_audit_application ON public.application;
CREATE TRIGGER trg_audit_application
AFTER INSERT OR UPDATE OR DELETE ON public.application
FOR EACH ROW
EXECUTE FUNCTION public.trgfn_audit_row();

-- 47. Audit contract changes.
DROP TRIGGER IF EXISTS trg_audit_contract ON public.contract;
CREATE TRIGGER trg_audit_contract
AFTER INSERT OR UPDATE OR DELETE ON public.contract
FOR EACH ROW
EXECUTE FUNCTION public.trgfn_audit_row();

-- 48. Audit payment changes.
DROP TRIGGER IF EXISTS trg_audit_payment ON public.payment;
CREATE TRIGGER trg_audit_payment
AFTER INSERT OR UPDATE OR DELETE ON public.payment
FOR EACH ROW
EXECUTE FUNCTION public.trgfn_audit_row();

-- 49. Audit application workflow status changes.
DROP TRIGGER IF EXISTS trg_audit_application_state ON public.application_state;
CREATE TRIGGER trg_audit_application_state
AFTER INSERT OR UPDATE OR DELETE ON public.application_state
FOR EACH ROW
EXECUTE FUNCTION public.trgfn_audit_row();



-- Дополнительная целостность распределения оплат.
-- Резервируются и PAID, и PENDING/CANCELLED распределения. Для повторного
-- использования суммы отменённого платежа сначала удалите его распределения.
CREATE OR REPLACE FUNCTION public.kk_trg_validate_payment_allocation()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_payment_amount numeric;
    v_period_amount numeric;
    v_allocated numeric;
    v_old_payment_id bigint;
    v_old_schedule_id bigint;
BEGIN
    IF TG_TABLE_NAME = 'payment_schedule' THEN
        IF NEW.period_start > NEW.period_end THEN
            RAISE EXCEPTION 'Начало периода оплаты позже его конца.';
        END IF;
        IF TG_OP = 'UPDATE' THEN
            SELECT COALESCE(SUM(a.amount), 0) INTO v_allocated
            FROM public.payment_allocation a WHERE a.payment_schedule_id = OLD.payment_schedule_id;
            IF v_allocated > NEW.amount THEN
                RAISE EXCEPTION 'Начисление % меньше уже распределённой суммы %.', NEW.amount, v_allocated;
            END IF;
            IF (NEW.contract_id <> OLD.contract_id OR NEW.payment_schedule_id <> OLD.payment_schedule_id)
               AND v_allocated > 0 THEN
                RAISE EXCEPTION 'Нельзя переносить оплаченный период на другой договор или менять его ID.';
            END IF;
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        v_old_payment_id := OLD.payment_id;
        v_old_schedule_id := OLD.payment_schedule_id;
    END IF;
    -- Блокировки родителей сериализуют конкурирующие распределения.
    SELECT p.amount INTO v_payment_amount FROM public.payment p
    WHERE p.payment_id = NEW.payment_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Платёж % не найден.', NEW.payment_id; END IF;
    SELECT s.amount INTO v_period_amount FROM public.payment_schedule s
    WHERE s.payment_schedule_id = NEW.payment_schedule_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Период оплаты % не найден.', NEW.payment_schedule_id; END IF;

    SELECT COALESCE(SUM(a.amount), 0) INTO v_allocated
    FROM public.payment_allocation a
    WHERE a.payment_id = NEW.payment_id
      AND (a.payment_id, a.payment_schedule_id) IS DISTINCT FROM (v_old_payment_id, v_old_schedule_id);
    IF v_allocated + NEW.amount > v_payment_amount THEN
        RAISE EXCEPTION 'Распределение превышает сумму платежа %.', NEW.payment_id;
    END IF;
    SELECT COALESCE(SUM(a.amount), 0) INTO v_allocated
    FROM public.payment_allocation a
    WHERE a.payment_schedule_id = NEW.payment_schedule_id
      AND (a.payment_id, a.payment_schedule_id) IS DISTINCT FROM (v_old_payment_id, v_old_schedule_id);
    IF v_allocated + NEW.amount > v_period_amount THEN
        RAISE EXCEPTION 'Распределение превышает начисление по периоду %.', NEW.payment_schedule_id;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS kk_validate_payment_allocation ON public.payment_allocation;
CREATE TRIGGER kk_validate_payment_allocation
BEFORE INSERT OR UPDATE ON public.payment_allocation
FOR EACH ROW EXECUTE FUNCTION public.kk_trg_validate_payment_allocation();

DROP TRIGGER IF EXISTS kk_validate_payment_schedule ON public.payment_schedule;
CREATE TRIGGER kk_validate_payment_schedule
BEFORE INSERT OR UPDATE ON public.payment_schedule
FOR EACH ROW EXECUTE FUNCTION public.kk_trg_validate_payment_allocation();

-- При повторной установке не принимаем уже испорченные распределения.
DO $existing_financial_data$
BEGIN
    IF EXISTS (SELECT 1 FROM public.payment_allocation a JOIN public.payment p USING (payment_id)
               GROUP BY p.payment_id, p.amount HAVING SUM(a.amount) > p.amount)
       OR EXISTS (SELECT 1 FROM public.payment_allocation a JOIN public.payment_schedule s USING (payment_schedule_id)
                  GROUP BY s.payment_schedule_id, s.amount HAVING SUM(a.amount) > s.amount)
       OR EXISTS (SELECT 1 FROM public.payment_schedule s WHERE s.period_start > s.period_end) THEN
        RAISE EXCEPTION 'Найдены некорректные периоды или избыточные распределения. Данные не изменены; исправьте их перед установкой.';
    END IF;
    IF (SELECT a.atttypid FROM pg_attribute a WHERE a.attrelid = 'public.payment'::regclass
        AND a.attname = 'periodicity' AND NOT a.attisdropped)
        IS DISTINCT FROM 'public.payment_periodicity'::regtype::oid THEN
        RAISE EXCEPTION 'Существующий payment.periodicity имеет другой тип.';
    END IF;
END;
$existing_financial_data$;


COMMIT;

-- ============================================================
-- ПРИМЕРЫ. Все закомментированы; замените ID на существующие.
-- ============================================================
-- 1. Неоплата семестра:
-- SELECT * FROM public.kk_students_unpaid_semester('2026-09-01', '2027-01-31');
-- 2. Недостающие документы; NULL-год означает любой год испытаний:
-- SELECT * FROM public.kk_students_missing_documents();
-- SELECT EXISTS(SELECT 1 FROM public.kk_students_missing_documents()) AS has_missing_documents;
-- 3. Полученные деньги (все годы / выбранный период):
-- SELECT public.kk_paid_tuition_total();
-- SELECT public.kk_paid_tuition_total('2026-01-01', '2026-12-31');
-- 4. Специальность ID=1, минимум 180 баллов, 20 мест, приоритет 1, кампания ID=1:
-- SELECT * FROM public.kk_specialty_admission_list(1, 180, 20, 1, 1);
-- 5. Должники на сегодня:
-- SELECT * FROM public.kk_debtors();
-- 6. Заявление абитуриента ID=1 в кампанию ID=1 (дата входит в её границы):
-- SELECT public.kk_create_application(1, 1, '2026-0001', '2026-07-01');
-- 7–11. ID периода оплаты и ID договора:
-- SELECT public.kk_period_debt(1);
-- SELECT public.kk_period_overdue_debt(1);
-- SELECT public.kk_contract_accrued(1);
-- SELECT public.kk_contract_paid(1);
-- SELECT public.kk_contract_debt(1);
-- 12. Пять популярных специальностей в кампании ID=1:
-- SELECT * FROM public.kk_top_specialties(5, 1);

-- Добавление выбора направления (приоритет уникален у абитуриента в кампании):
-- INSERT INTO public.direction_choice(applicant_id, educational_program_id, admission_campaign_id, priority)
-- VALUES (1, 1, 1, 1);

-- Установка периодичности существующего платежа:
-- UPDATE public.payment SET periodicity = 'SEMESTER' WHERE payment_id = 1;

-- Начисление за семестр договора ID=1:
-- INSERT INTO public.payment_schedule(contract_id, installment_no, period_start, period_end, due_date, amount)
-- VALUES (1, 1, '2026-09-01', '2027-01-31', '2026-09-01', 60000)
-- RETURNING payment_schedule_id;
-- Зарегистрируйте фактический платёж и распределите его на ID этого начисления:
-- INSERT INTO public.payment(payment_date, amount, payment_status, payment_method, periodicity)
-- VALUES (CURRENT_DATE, 20000, 'PAID', 'BANK_TRANSFER', 'SEMESTER') RETURNING payment_id;
-- INSERT INTO public.payment_allocation(payment_id, payment_schedule_id, amount) VALUES (1, 1, 20000);
-- Эти действия также позволяют связать старые платежи из contract.payment_id
-- с начислениями. Повторно записывать сам платёж при этом не требуется.
