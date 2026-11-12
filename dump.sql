--
-- PostgreSQL database dump
--

\restrict eK0I1sEDwx0fOFDY0YvXz8PfNMsWDoDvgBBUgeYCsHvIOuIBMa9yLznY6RJEteh

-- Dumped from database version 17.11
-- Dumped by pg_dump version 17.11

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: application_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.application_status AS ENUM (
    'PROCESSED',
    'CANCELLED',
    'COMPLETED'
);


--
-- Name: order_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.order_type AS ENUM (
    'ENROLLMENT',
    'EXPULSION',
    'TRANSFER'
);


--
-- Name: payment_method; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.payment_method AS ENUM (
    'CASH',
    'CARD',
    'BANK_TRANSFER'
);


--
-- Name: payment_periodicity; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.payment_periodicity AS ENUM (
    'MONTHLY',
    'YEARLY',
    'SEMESTER'
);


--
-- Name: payment_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.payment_status AS ENUM (
    'PENDING',
    'PAID',
    'CANCELLED'
);


--
-- Name: kk_add_applicant_certificate(text, text, text, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.kk_add_applicant_certificate(p_series text, p_passport_number text, p_certificate_number text, p_certificate_upload_date date) RETURNS TABLE(applicant_id bigint, full_name character varying, birth_date date, snils character varying, passport_series character varying, passport_number character varying, issued_by character varying, issue_date date, subdivision_code character varying, address character varying, certificate_number character varying, certificate_upload_date date)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_applicant_id bigint;
    v_passport_id bigint;
    v_matches bigint;
    v_series text := NULLIF(regexp_replace(p_series, '[[:space:]]+', '', 'g'), '');
    v_number text := NULLIF(regexp_replace(p_passport_number, '[[:space:]]+', '', 'g'), '');
    v_certificate text := NULLIF(btrim(p_certificate_number), '');
BEGIN
    IF v_series IS NULL OR v_number IS NULL OR v_certificate IS NULL
       OR p_certificate_upload_date IS NULL THEN
        RAISE EXCEPTION 'Укажите серию и номер паспорта, номер и дату загрузки аттестата';
    END IF;

    PERFORM pg_advisory_xact_lock(73203, 2);

    SELECT COUNT(*), MIN(pd.applicant_id), MIN(p.passport_id)
    INTO v_matches, v_applicant_id, v_passport_id
    FROM public.passport AS p
    JOIN public.personal_data AS pd ON pd.personal_data_id = p.personal_data_id
    WHERE regexp_replace(p.series, '[[:space:]]+', '', 'g') = v_series
      AND regexp_replace(p.passport_number, '[[:space:]]+', '', 'g') = v_number;

    IF v_matches = 0 THEN
        RAISE EXCEPTION 'Абитуриент с таким паспортом не найден';
    ELSIF v_matches > 1 THEN
        RAISE EXCEPTION 'Найдено несколько записей с таким паспортом';
    END IF;

    INSERT INTO public.certificate (applicant_id, certificate_number, upload_date)
    VALUES (v_applicant_id, v_certificate, p_certificate_upload_date)
    ON CONFLICT ON CONSTRAINT certificate_pkey DO NOTHING;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'У этого абитуриента уже есть аттестат';
    END IF;

    RETURN QUERY
    SELECT pd.applicant_id, p.full_name, p.birth_date, pd.snils,
           p.series, p.passport_number, p.issued_by, p.issue_date,
           p.subdivision_code, p.address, c.certificate_number, c.upload_date
    FROM public.passport AS p
    JOIN public.personal_data AS pd ON pd.personal_data_id = p.personal_data_id
    JOIN public.certificate AS c ON c.applicant_id = pd.applicant_id
    WHERE p.passport_id = v_passport_id;
END;
$$;


--
-- Name: kk_add_applicant_profile(text, text, text, date, text, date, text, text, text, text, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.kk_add_applicant_profile(p_series text, p_passport_number text, p_full_name text, p_birth_date date, p_issued_by text, p_issue_date date, p_subdivision_code text, p_address text, p_snils text, p_certificate_number text DEFAULT NULL::text, p_certificate_upload_date date DEFAULT NULL::date) RETURNS TABLE(applicant_id bigint, full_name character varying, birth_date date, snils character varying, passport_series character varying, passport_number character varying, issued_by character varying, issue_date date, subdivision_code character varying, address character varying, certificate_number character varying, certificate_upload_date date)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_applicant_id bigint;
    v_personal_data_id bigint;
    v_series text := regexp_replace(p_series, '[[:space:]]+', '', 'g');
    v_number text := regexp_replace(p_passport_number, '[[:space:]]+', '', 'g');
    v_certificate text := NULLIF(btrim(p_certificate_number), '');
BEGIN
    IF p_birth_date IS NULL OR p_issue_date IS NULL OR EXISTS (
        SELECT 1
        FROM unnest(ARRAY[v_series, v_number, p_full_name, p_issued_by,
                          p_subdivision_code, p_address, p_snils]) AS input(value)
        WHERE NULLIF(btrim(input.value), '') IS NULL
    ) THEN
        RAISE EXCEPTION 'Заполните все паспортные данные и СНИЛС';
    END IF;

    IF (v_certificate IS NULL) <> (p_certificate_upload_date IS NULL) THEN
        RAISE EXCEPTION 'Для аттестата нужны номер и дата загрузки';
    END IF;

    PERFORM pg_advisory_xact_lock(73203, 2);

    IF EXISTS (
        SELECT 1 FROM public.passport AS p
        WHERE regexp_replace(p.series, '[[:space:]]+', '', 'g') = v_series
          AND regexp_replace(p.passport_number, '[[:space:]]+', '', 'g') = v_number
    ) THEN
        RAISE EXCEPTION 'Профиль с таким паспортом уже существует';
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.personal_data AS pd
        WHERE regexp_replace(pd.snils, '[[:space:]-]+', '', 'g')
            = regexp_replace(p_snils, '[[:space:]-]+', '', 'g')
    ) THEN
        RAISE EXCEPTION 'Профиль с таким СНИЛС уже существует';
    END IF;

    INSERT INTO public.applicant DEFAULT VALUES
    RETURNING applicant.applicant_id INTO v_applicant_id;

    INSERT INTO public.personal_data (applicant_id, snils)
    VALUES (v_applicant_id, btrim(p_snils))
    RETURNING personal_data.personal_data_id INTO v_personal_data_id;

    INSERT INTO public.passport (
        personal_data_id, series, passport_number, full_name, birth_date,
        issued_by, issue_date, subdivision_code, address
    )
    VALUES (
        v_personal_data_id, v_series, v_number, btrim(p_full_name), p_birth_date,
        btrim(p_issued_by), p_issue_date, btrim(p_subdivision_code), btrim(p_address)
    );

    IF v_certificate IS NOT NULL THEN
        INSERT INTO public.certificate (applicant_id, certificate_number, upload_date)
        VALUES (v_applicant_id, v_certificate, p_certificate_upload_date);
    END IF;

    RETURN QUERY
    SELECT pd.applicant_id, p.full_name, p.birth_date, pd.snils,
           p.series, p.passport_number, p.issued_by, p.issue_date,
           p.subdivision_code, p.address, c.certificate_number, c.upload_date
    FROM public.personal_data AS pd
    JOIN public.passport AS p ON p.personal_data_id = pd.personal_data_id
    LEFT JOIN public.certificate AS c ON c.applicant_id = pd.applicant_id
    WHERE pd.personal_data_id = v_personal_data_id;
END;
$$;


--
-- Name: kk_student_debtors(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.kk_student_debtors() RETURNS TABLE(full_name character varying, direction_code character varying, group_name character varying, debt_amount numeric)
    LANGUAGE sql STABLE
    AS $$
    SELECT info.full_name, info.direction_code, info.group_name, report.debt_amount
    FROM public.student AS s
    CROSS JOIN LATERAL public.kk_student_payment_report(s.record_book_number) AS report
    CROSS JOIN LATERAL public.kk_student_study_info(s.record_book_number) AS info
    WHERE report.debt_amount > 0
    ORDER BY report.debt_amount DESC, info.full_name, s.applicant_id;
$$;


--
-- Name: kk_student_list(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.kk_student_list() RETURNS TABLE(full_name character varying, direction_code character varying, group_name character varying, total_score bigint, "рейтинг по экзаменам" numeric, paid_this_year numeric)
    LANGUAGE sql STABLE
    AS $$
    SELECT info.full_name,
           info.direction_code,
           info.group_name,
           COALESCE(exams.total_score, 0),
           info."рейтинг по экзаменам",
           COALESCE(payments.paid_total, 0)
    FROM public.student AS s
    CROSS JOIN LATERAL public.kk_student_study_info(s.record_book_number) AS info
    LEFT JOIN LATERAL (
        SELECT SUM(er.score) AS total_score
        FROM public.exam_result AS er
        WHERE er.applicant_id = s.applicant_id
    ) AS exams ON true
    LEFT JOIN LATERAL (
        SELECT SUM(p.amount) AS paid_total
        FROM public.contract AS c
        JOIN public.payment AS p ON p.contract_id = c.contract_id
        WHERE c.student_id = s.applicant_id
          AND p.payment_status = 'PAID'
          AND p.payment_date BETWEEN date_trunc('year', CURRENT_DATE::timestamp)::date
                                 AND CURRENT_DATE
    ) AS payments ON true
    ORDER BY info.full_name, s.applicant_id;
$$;


--
-- Name: kk_student_payment_contract(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.kk_student_payment_contract(p_record_book_number text, p_direction_code text) RETURNS TABLE(full_name character varying, direction_code character varying, study_duration integer, amount_to_pay numeric)
    LANGUAGE sql STABLE
    AS $$
    SELECT info.full_name, ep.direction_code, ep.study_duration, c.amount
    FROM public.student AS s
    JOIN public.contract AS c ON c.student_id = s.applicant_id
    JOIN public.educational_program AS ep
        ON ep.educational_program_id = c.educational_program_id
    CROSS JOIN LATERAL public.kk_student_study_info(s.record_book_number) AS info
    WHERE s.record_book_number = p_record_book_number
      AND ep.direction_code = p_direction_code
    ORDER BY c.conclusion_date DESC, c.contract_id DESC
    LIMIT 1;
$$;


--
-- Name: kk_student_payment_report(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.kk_student_payment_report(p_record_book_number text) RETURNS TABLE(full_name character varying, faculty_name character varying, study_year integer, "рейтинг по экзаменам" numeric, paid_amount numeric, remaining_to_pay numeric, last_paid_month text, debt_amount numeric)
    LANGUAGE plpgsql STABLE
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


--
-- Name: kk_student_rating(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.kk_student_rating(p_direction_code text) RETURNS TABLE(full_name character varying, snils character varying, priority integer, total_score bigint)
    LANGUAGE sql STABLE
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


--
-- Name: kk_student_study_info(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.kk_student_study_info(p_record_book_number text) RETURNS TABLE(full_name character varying, faculty_name character varying, direction_code character varying, group_name character varying, "рейтинг по экзаменам" numeric)
    LANGUAGE sql STABLE
    AS $$
    SELECT
        person.full_name,
        study.faculty_name,
        study.direction_code,
        study.group_name,
        (
            SELECT ROUND(AVG(er.score), 2)
            FROM public.exam_result AS er
            WHERE er.applicant_id = s.applicant_id
        )
    FROM public.student AS s
    LEFT JOIN LATERAL (
        SELECT p.full_name
        FROM public.personal_data AS pd
        JOIN public.passport AS p ON p.personal_data_id = pd.personal_data_id
        WHERE pd.applicant_id = s.applicant_id
          AND p.full_name IS NOT NULL
        ORDER BY p.issue_date DESC NULLS LAST, p.passport_id DESC
        LIMIT 1
    ) AS person ON true
    LEFT JOIN LATERAL (
        SELECT f.faculty_name, sp.specialty_code AS direction_code, sg.group_name
        FROM public.student_study_group AS ssg
        JOIN public.study_group AS sg ON sg.study_group_id = ssg.study_group_id
        JOIN public.specialty AS sp ON sp.specialty_id = sg.specialty_id
        JOIN public.faculty AS f ON f.faculty_id = sp.faculty_id
        WHERE ssg.student_id = s.applicant_id
        ORDER BY sg.admission_year DESC, sg.study_group_id DESC
        LIMIT 1
    ) AS study ON true
    WHERE s.applicant_id = (
        SELECT matched.applicant_id
        FROM public.student AS matched
        WHERE matched.record_book_number = p_record_book_number
    );
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: admission_campaign; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admission_campaign (
    admission_campaign_id bigint NOT NULL,
    academic_year character varying(20) NOT NULL,
    start_date date NOT NULL,
    end_date date NOT NULL
);


--
-- Name: admission_campaign_admission_campaign_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.admission_campaign_admission_campaign_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: admission_campaign_admission_campaign_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.admission_campaign_admission_campaign_id_seq OWNED BY public.admission_campaign.admission_campaign_id;


--
-- Name: applicant; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.applicant (
    applicant_id bigint NOT NULL,
    phone character varying(30),
    email character varying(254)
);


--
-- Name: applicant_applicant_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.applicant_applicant_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: applicant_applicant_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.applicant_applicant_id_seq OWNED BY public.applicant.applicant_id;


--
-- Name: application; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.application (
    application_id bigint NOT NULL,
    admission_campaign_id bigint NOT NULL,
    applicant_id bigint NOT NULL,
    application_number character varying(50) NOT NULL,
    submission_date date NOT NULL,
    application_status public.application_status NOT NULL
);


--
-- Name: application_application_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.application_application_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: application_application_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.application_application_id_seq OWNED BY public.application.application_id;


--
-- Name: application_educational_program_priority; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.application_educational_program_priority (
    application_id bigint NOT NULL,
    educational_program_id bigint NOT NULL,
    priority integer NOT NULL,
    CONSTRAINT chk_aepp_priority_positive CHECK ((priority > 0))
);


--
-- Name: certificate; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.certificate (
    applicant_id bigint NOT NULL,
    certificate_number character varying(100) NOT NULL,
    upload_date date NOT NULL
);


--
-- Name: contract; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contract (
    contract_id bigint NOT NULL,
    student_id bigint NOT NULL,
    educational_program_id bigint NOT NULL,
    order_id bigint NOT NULL,
    contract_number character varying(100) NOT NULL,
    conclusion_date date NOT NULL,
    amount numeric(12,2) NOT NULL,
    start_date date NOT NULL,
    end_date date NOT NULL
);


--
-- Name: contract_contract_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.contract_contract_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: contract_contract_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.contract_contract_id_seq OWNED BY public.contract.contract_id;


--
-- Name: educational_program; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.educational_program (
    educational_program_id bigint NOT NULL,
    specialty_id bigint NOT NULL,
    direction_code character varying(50) NOT NULL,
    program_name character varying(255) NOT NULL,
    study_duration integer NOT NULL,
    study_form character varying(50) NOT NULL
);


--
-- Name: educational_program_educational_program_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.educational_program_educational_program_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: educational_program_educational_program_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.educational_program_educational_program_id_seq OWNED BY public.educational_program.educational_program_id;


--
-- Name: enrollment_order; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.enrollment_order (
    order_id bigint NOT NULL,
    order_number character varying(100) NOT NULL,
    order_date date NOT NULL,
    order_type public.order_type NOT NULL
);


--
-- Name: enrollment_order_order_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.enrollment_order_order_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: enrollment_order_order_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.enrollment_order_order_id_seq OWNED BY public.enrollment_order.order_id;


--
-- Name: exam_result; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.exam_result (
    exam_result_id bigint NOT NULL,
    applicant_id bigint NOT NULL,
    score integer NOT NULL,
    exam_year integer NOT NULL,
    exam_type character varying(100) NOT NULL
);


--
-- Name: exam_result_exam_result_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.exam_result_exam_result_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: exam_result_exam_result_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.exam_result_exam_result_id_seq OWNED BY public.exam_result.exam_result_id;


--
-- Name: faculty; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.faculty (
    faculty_id bigint NOT NULL,
    faculty_name character varying(255) NOT NULL
);


--
-- Name: faculty_faculty_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.faculty_faculty_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: faculty_faculty_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.faculty_faculty_id_seq OWNED BY public.faculty.faculty_id;


--
-- Name: passport; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.passport (
    passport_id bigint NOT NULL,
    personal_data_id bigint NOT NULL,
    series character varying(20),
    passport_number character varying(30),
    issued_by character varying(255),
    issue_date date,
    subdivision_code character varying(20),
    full_name character varying(255),
    birth_date date,
    address character varying(500)
);


--
-- Name: passport_passport_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.passport_passport_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: passport_passport_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.passport_passport_id_seq OWNED BY public.passport.passport_id;


--
-- Name: payment; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payment (
    payment_id bigint NOT NULL,
    contract_id bigint NOT NULL,
    payment_date date NOT NULL,
    amount numeric(12,2) NOT NULL,
    payment_status public.payment_status NOT NULL,
    payment_method public.payment_method NOT NULL,
    periodicity public.payment_periodicity DEFAULT 'MONTHLY'::public.payment_periodicity NOT NULL
);


--
-- Name: payment_payment_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.payment_payment_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: payment_payment_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.payment_payment_id_seq OWNED BY public.payment.payment_id;


--
-- Name: personal_data; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.personal_data (
    personal_data_id bigint NOT NULL,
    applicant_id bigint NOT NULL,
    snils character varying(20) NOT NULL
);


--
-- Name: personal_data_personal_data_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.personal_data_personal_data_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: personal_data_personal_data_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.personal_data_personal_data_id_seq OWNED BY public.personal_data.personal_data_id;


--
-- Name: specialty; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.specialty (
    specialty_id bigint NOT NULL,
    faculty_id bigint NOT NULL,
    specialty_code character varying(50) NOT NULL
);


--
-- Name: specialty_specialty_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.specialty_specialty_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: specialty_specialty_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.specialty_specialty_id_seq OWNED BY public.specialty.specialty_id;


--
-- Name: student; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.student (
    applicant_id bigint NOT NULL,
    record_book_number character varying(50) NOT NULL,
    enrollment_date date NOT NULL
);


--
-- Name: student_study_group; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.student_study_group (
    student_id bigint NOT NULL,
    study_group_id bigint NOT NULL
);


--
-- Name: study_group; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.study_group (
    study_group_id bigint NOT NULL,
    specialty_id bigint NOT NULL,
    group_name character varying(100) NOT NULL,
    course integer NOT NULL,
    admission_year integer NOT NULL
);


--
-- Name: study_group_study_group_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.study_group_study_group_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: study_group_study_group_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.study_group_study_group_id_seq OWNED BY public.study_group.study_group_id;


--
-- Name: admission_campaign admission_campaign_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admission_campaign ALTER COLUMN admission_campaign_id SET DEFAULT nextval('public.admission_campaign_admission_campaign_id_seq'::regclass);


--
-- Name: applicant applicant_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.applicant ALTER COLUMN applicant_id SET DEFAULT nextval('public.applicant_applicant_id_seq'::regclass);


--
-- Name: application application_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.application ALTER COLUMN application_id SET DEFAULT nextval('public.application_application_id_seq'::regclass);


--
-- Name: contract contract_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract ALTER COLUMN contract_id SET DEFAULT nextval('public.contract_contract_id_seq'::regclass);


--
-- Name: educational_program educational_program_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.educational_program ALTER COLUMN educational_program_id SET DEFAULT nextval('public.educational_program_educational_program_id_seq'::regclass);


--
-- Name: enrollment_order order_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enrollment_order ALTER COLUMN order_id SET DEFAULT nextval('public.enrollment_order_order_id_seq'::regclass);


--
-- Name: exam_result exam_result_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exam_result ALTER COLUMN exam_result_id SET DEFAULT nextval('public.exam_result_exam_result_id_seq'::regclass);


--
-- Name: faculty faculty_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.faculty ALTER COLUMN faculty_id SET DEFAULT nextval('public.faculty_faculty_id_seq'::regclass);


--
-- Name: passport passport_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.passport ALTER COLUMN passport_id SET DEFAULT nextval('public.passport_passport_id_seq'::regclass);


--
-- Name: payment payment_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment ALTER COLUMN payment_id SET DEFAULT nextval('public.payment_payment_id_seq'::regclass);


--
-- Name: personal_data personal_data_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_data ALTER COLUMN personal_data_id SET DEFAULT nextval('public.personal_data_personal_data_id_seq'::regclass);


--
-- Name: specialty specialty_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.specialty ALTER COLUMN specialty_id SET DEFAULT nextval('public.specialty_specialty_id_seq'::regclass);


--
-- Name: study_group study_group_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.study_group ALTER COLUMN study_group_id SET DEFAULT nextval('public.study_group_study_group_id_seq'::regclass);


--
-- Data for Name: admission_campaign; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.admission_campaign (admission_campaign_id, academic_year, start_date, end_date) FROM stdin;
1	2025/2026	2025-06-20	2025-08-31
2	2026/2027	2026-06-20	2026-08-31
\.


--
-- Data for Name: applicant; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.applicant (applicant_id, phone, email) FROM stdin;
1	+7 964 123-11-01	anna.leskova@mail.ru
2	+7 964 123-11-02	mikhail.vetrov@mail.ru
3	+7 964 123-11-03	daria.rodina@mail.ru
4	+7 234 123-11-04	artem.lanskoy@mail.ru
5	+7 234 123-11-05	polina.mironova@mail.ru
6	+7 234 123-11-06	kirill.lipatov@mail.ru
7	+7 234 123-11-07	eliza.zorina@mail.ru
8	+7 905 123-11-08	daniil.ryabov@mail.ru
9	+7 905 123-22-09	sofia.polyanskaya@mail.ru
10	+7 905 123-22-10	ivan.yarovoy@mail.ru
11	\N	\N
12	\N	\N
13	\N	\N
14	\N	\N
\.


--
-- Data for Name: application; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.application (application_id, admission_campaign_id, applicant_id, application_number, submission_date, application_status) FROM stdin;
1	2	1	П-2026-1	2026-07-06	COMPLETED
2	2	2	П-2026-2	2026-07-07	COMPLETED
3	2	3	П-2026-3	2026-07-08	COMPLETED
4	2	4	П-2026-4	2026-07-09	COMPLETED
5	2	5	П-2026-5	2026-07-10	COMPLETED
6	2	6	П-2026-6	2026-07-11	COMPLETED
7	1	7	П-2025-7	2025-07-12	COMPLETED
8	1	8	П-2025-8	2025-07-13	COMPLETED
9	2	9	П-2026-9	2026-07-14	PROCESSED
10	2	10	П-2026-10	2026-07-15	CANCELLED
\.


--
-- Data for Name: application_educational_program_priority; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.application_educational_program_priority (application_id, educational_program_id, priority) FROM stdin;
1	1	1
1	2	2
2	1	1
2	2	2
3	2	1
3	3	2
4	2	1
4	3	2
5	3	1
5	1	2
6	3	1
6	1	2
7	1	1
7	2	2
8	1	1
8	2	2
9	2	1
9	3	2
10	3	1
10	1	2
\.


--
-- Data for Name: certificate; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.certificate (applicant_id, certificate_number, upload_date) FROM stdin;
1	00000000000001	2026-07-06
2	00000000000002	2026-07-07
3	00000000000003	2026-07-08
4	00000000000004	2026-07-09
5	00000000000005	2026-07-10
6	00000000000006	2026-07-11
7	00000000000007	2025-07-12
8	00000000000008	2025-07-13
11	ТЕСТ-900001	2026-11-12
12	ТЕСТ-900002	2026-11-12
13	ТЕСТ-900001	2026-11-12
14	ТЕСТ-900123	2026-11-12
\.


--
-- Data for Name: contract; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.contract (contract_id, student_id, educational_program_id, order_id, contract_number, conclusion_date, amount, start_date, end_date) FROM stdin;
1	1	1	2	Д-2026-1	2026-08-28	720000.00	2026-09-01	2030-06-30
2	3	2	2	Д-2026-3	2026-08-28	680000.00	2026-09-01	2030-06-30
3	5	3	2	Д-2026-5	2026-08-28	560000.00	2026-09-01	2030-06-30
4	7	1	1	Д-2025-7	2025-08-28	640000.00	2025-09-01	2029-06-30
5	2	1	2	Д-2026-2	2026-08-28	720000.00	2026-09-01	2030-06-30
6	4	2	2	Д-2026-4	2026-08-28	680000.00	2026-09-01	2030-06-30
7	6	3	2	Д-2026-6	2026-08-28	560000.00	2026-09-01	2030-06-30
8	8	1	1	Д-2025-8	2025-08-28	640000.00	2025-09-01	2029-06-30
\.


--
-- Data for Name: educational_program; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.educational_program (educational_program_id, specialty_id, direction_code, program_name, study_duration, study_form) FROM stdin;
1	1	09.03.04	Программная инженерия	4	Очная
2	2	09.03.03	Прикладная информатика	4	Очная
3	3	38.03.01	Экономика	4	Очная
\.


--
-- Data for Name: enrollment_order; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.enrollment_order (order_id, order_number, order_date, order_type) FROM stdin;
1	2025-З/01	2025-08-25	ENROLLMENT
2	2026-З/01	2026-08-25	ENROLLMENT
\.


--
-- Data for Name: exam_result; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.exam_result (exam_result_id, applicant_id, score, exam_year, exam_type) FROM stdin;
1	1	95	2026	Математика
2	1	91	2026	Русский язык
3	1	94	2026	Информатика
4	2	97	2026	Математика
5	2	89	2026	Русский язык
6	2	94	2026	Информатика
7	3	87	2026	Математика
8	3	85	2026	Русский язык
9	3	90	2026	Информатика
10	4	82	2026	Математика
11	4	79	2026	Русский язык
12	4	85	2026	Информатика
13	5	84	2026	Математика
14	5	91	2026	Русский язык
15	5	87	2026	Обществознание
16	6	79	2026	Математика
17	6	83	2026	Русский язык
18	6	88	2026	Обществознание
19	7	91	2025	Математика
20	7	88	2025	Русский язык
21	7	93	2025	Информатика
22	8	86	2025	Математика
23	8	81	2025	Русский язык
24	8	89	2025	Информатика
25	9	73	2026	Математика
26	9	78	2026	Русский язык
27	9	76	2026	Информатика
28	10	68	2026	Математика
29	10	72	2026	Русский язык
30	10	74	2026	Обществознание
\.


--
-- Data for Name: faculty; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.faculty (faculty_id, faculty_name) FROM stdin;
1	Факультет информационных технологий
2	Факультет экономики и управления
\.


--
-- Data for Name: passport; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.passport (passport_id, personal_data_id, series, passport_number, issued_by, issue_date, subdivision_code, full_name, birth_date, address) FROM stdin;
1	1	0120	000001	ОВМ Центрального района	2022-02-14	120-050	Анна Сергеевна Лескова	2008-02-14	г. Примерск, ул. Студенческая, д. 1
2	2	0120	000002	ОВМ Центрального района	2022-05-09	120-050	Михаил Олегович Ветров	2008-05-09	г. Примерск, ул. Студенческая, д. 2
3	3	0120	000003	ОВМ Центрального района	2021-11-21	120-050	Дарья Ильинична Родина	2007-11-21	г. Примерск, ул. Студенческая, д. 3
4	4	0120	000004	ОВМ Центрального района	2022-01-30	120-050	Артём Павлович Ланской	2008-01-30	г. Примерск, ул. Студенческая, д. 4
5	5	0120	000005	ОВМ Центрального района	2022-04-16	120-050	Полина Андреевна Миронова	2008-04-16	г. Примерск, ул. Студенческая, д. 5
6	6	0120	000006	ОВМ Центрального района	2022-03-12	120-050	Кирилл Денисович Липатов	2008-03-12	г. Примерск, ул. Студенческая, д. 6
7	7	0120	000007	ОВМ Центрального района	2021-02-25	120-050	Елизавета Романовна Зорина	2007-02-25	г. Примерск, ул. Студенческая, д. 7
8	8	0120	000008	ОВМ Центрального района	2021-06-03	120-050	Даниил Викторович Рябов	2007-06-03	г. Примерск, ул. Студенческая, д. 8
9	9	0120	000009	ОВМ Центрального района	2022-07-01	120-050	София Никитична Полянская	2008-07-01	г. Примерск, ул. Студенческая, д. 9
10	10	0120	000010	ОВМ Центрального района	2022-08-17	120-050	Иван Алексеевич Яровой	2008-08-17	г. Примерск, ул. Студенческая, д. 10
11	11	0000	900001	Учебный отдел	2022-03-15	000-000	Алексей Иванович Тестов	2008-03-12	г. Примерск, ул. Учебная, д. 1
12	12	0000	900002	Учебный отдел	2022-05-24	000-000	Мария Олеговна Примерова	2008-05-21	г. Примерск, ул. Учебная, д. 2
13	13	0001	900002	Учебный отдел	2022-03-15	000-001	Алексей Иванович Тестов	2008-03-12	г. Примерск, ул. Учебная, д. 1
14	14	0000	900003	Учебный отдел	2022-05-24	000-000	Мария Олеговна Примерова	2008-05-21	г. Примерск, ул. Учебная, д. 2
\.


--
-- Data for Name: payment; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.payment (payment_id, contract_id, payment_date, amount, payment_status, payment_method, periodicity) FROM stdin;
1	1	2026-09-05	15000.00	PAID	CARD	MONTHLY
2	1	2026-10-05	15000.00	PAID	CARD	MONTHLY
3	1	2026-11-05	15000.00	PENDING	CARD	MONTHLY
4	2	2026-09-02	85000.00	PAID	BANK_TRANSFER	SEMESTER
5	2	2027-02-02	85000.00	PENDING	BANK_TRANSFER	SEMESTER
6	3	2026-09-03	140000.00	CANCELLED	CARD	YEARLY
7	3	2026-09-05	140000.00	PAID	CASH	YEARLY
8	4	2025-09-01	160000.00	PAID	BANK_TRANSFER	YEARLY
9	4	2026-09-01	160000.00	PAID	BANK_TRANSFER	YEARLY
10	5	2026-09-05	15000.00	PAID	CARD	MONTHLY
11	5	2026-10-05	15000.00	PAID	CARD	MONTHLY
12	5	2026-11-05	15000.00	PAID	CARD	MONTHLY
13	5	2026-12-05	15000.00	PENDING	CARD	MONTHLY
14	6	2026-09-03	40000.00	PAID	BANK_TRANSFER	SEMESTER
15	6	2026-09-15	45000.00	PENDING	BANK_TRANSFER	SEMESTER
16	7	2026-09-03	70000.00	PAID	BANK_TRANSFER	SEMESTER
17	7	2027-02-03	70000.00	PENDING	BANK_TRANSFER	SEMESTER
18	8	2025-09-05	16000.00	PAID	CARD	MONTHLY
19	8	2025-10-05	16000.00	PAID	CARD	MONTHLY
20	8	2025-11-05	16000.00	PAID	CARD	MONTHLY
21	8	2025-12-05	16000.00	PAID	CARD	MONTHLY
22	8	2026-01-05	16000.00	PAID	CARD	MONTHLY
23	8	2026-02-05	16000.00	PAID	CARD	MONTHLY
24	8	2026-03-05	16000.00	PAID	CARD	MONTHLY
25	8	2026-04-05	16000.00	PAID	CARD	MONTHLY
26	8	2026-05-05	16000.00	PAID	CARD	MONTHLY
27	8	2026-06-05	16000.00	PAID	CARD	MONTHLY
28	8	2026-09-05	16000.00	PAID	CARD	MONTHLY
29	8	2026-10-05	16000.00	PAID	CARD	MONTHLY
30	8	2026-11-05	16000.00	PENDING	CARD	MONTHLY
31	8	2026-12-05	16000.00	PENDING	CARD	MONTHLY
\.


--
-- Data for Name: personal_data; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.personal_data (personal_data_id, applicant_id, snils) FROM stdin;
1	1	123-111-001 00
2	2	234-222-002 00
3	3	345-333-003 00
4	4	456-444-004 00
5	5	567-555-005 00
6	6	678-666-006 00
7	7	789-777-007 00
8	8	890-888-008 00
9	9	436-999-009 00
10	10	122-876-010 00
11	11	000-000-901 00
12	12	000-000-902 00
13	13	000-000-902 12
14	14	111-111-111 22
\.


--
-- Data for Name: specialty; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.specialty (specialty_id, faculty_id, specialty_code) FROM stdin;
1	1	09.03.04
2	1	09.03.03
3	2	38.03.01
\.


--
-- Data for Name: student; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.student (applicant_id, record_book_number, enrollment_date) FROM stdin;
1	48371625	2026-09-01
2	91520487	2026-09-01
3	62743810	2026-09-01
4	35296174	2026-09-01
5	87406329	2026-09-01
6	14958263	2026-09-01
7	76031592	2025-09-01
8	21864705	2025-09-01
\.


--
-- Data for Name: student_study_group; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.student_study_group (student_id, study_group_id) FROM stdin;
1	1
2	1
3	2
4	2
5	3
6	3
7	4
8	4
\.


--
-- Data for Name: study_group; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.study_group (study_group_id, specialty_id, group_name, course, admission_year) FROM stdin;
1	1	ПИ-26-01	1	2026
2	2	ПИН-26-01	1	2026
3	3	ЭК-26-01	1	2026
4	1	ПИ-25-01	2	2025
\.


--
-- Name: admission_campaign_admission_campaign_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.admission_campaign_admission_campaign_id_seq', 2, true);


--
-- Name: applicant_applicant_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.applicant_applicant_id_seq', 14, true);


--
-- Name: application_application_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.application_application_id_seq', 10, true);


--
-- Name: contract_contract_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.contract_contract_id_seq', 8, true);


--
-- Name: educational_program_educational_program_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.educational_program_educational_program_id_seq', 3, true);


--
-- Name: enrollment_order_order_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.enrollment_order_order_id_seq', 2, true);


--
-- Name: exam_result_exam_result_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.exam_result_exam_result_id_seq', 30, true);


--
-- Name: faculty_faculty_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.faculty_faculty_id_seq', 2, true);


--
-- Name: passport_passport_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.passport_passport_id_seq', 14, true);


--
-- Name: payment_payment_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.payment_payment_id_seq', 31, true);


--
-- Name: personal_data_personal_data_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.personal_data_personal_data_id_seq', 14, true);


--
-- Name: specialty_specialty_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.specialty_specialty_id_seq', 3, true);


--
-- Name: study_group_study_group_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.study_group_study_group_id_seq', 4, true);


--
-- Name: admission_campaign admission_campaign_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admission_campaign
    ADD CONSTRAINT admission_campaign_pkey PRIMARY KEY (admission_campaign_id);


--
-- Name: applicant applicant_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.applicant
    ADD CONSTRAINT applicant_pkey PRIMARY KEY (applicant_id);


--
-- Name: application_educational_program_priority application_educational_program_priority_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.application_educational_program_priority
    ADD CONSTRAINT application_educational_program_priority_pkey PRIMARY KEY (application_id, educational_program_id);


--
-- Name: application application_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.application
    ADD CONSTRAINT application_pkey PRIMARY KEY (application_id);


--
-- Name: certificate certificate_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.certificate
    ADD CONSTRAINT certificate_pkey PRIMARY KEY (applicant_id);


--
-- Name: contract contract_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract
    ADD CONSTRAINT contract_pkey PRIMARY KEY (contract_id);


--
-- Name: educational_program educational_program_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.educational_program
    ADD CONSTRAINT educational_program_pkey PRIMARY KEY (educational_program_id);


--
-- Name: enrollment_order enrollment_order_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enrollment_order
    ADD CONSTRAINT enrollment_order_pkey PRIMARY KEY (order_id);


--
-- Name: exam_result exam_result_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exam_result
    ADD CONSTRAINT exam_result_pkey PRIMARY KEY (exam_result_id);


--
-- Name: faculty faculty_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.faculty
    ADD CONSTRAINT faculty_pkey PRIMARY KEY (faculty_id);


--
-- Name: passport passport_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.passport
    ADD CONSTRAINT passport_pkey PRIMARY KEY (passport_id);


--
-- Name: payment payment_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment
    ADD CONSTRAINT payment_pkey PRIMARY KEY (payment_id);


--
-- Name: personal_data personal_data_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_data
    ADD CONSTRAINT personal_data_pkey PRIMARY KEY (personal_data_id);


--
-- Name: specialty specialty_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.specialty
    ADD CONSTRAINT specialty_pkey PRIMARY KEY (specialty_id);


--
-- Name: student student_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.student
    ADD CONSTRAINT student_pkey PRIMARY KEY (applicant_id);


--
-- Name: study_group study_group_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.study_group
    ADD CONSTRAINT study_group_pkey PRIMARY KEY (study_group_id);


--
-- Name: application_educational_program_priority fk_aepp_application_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.application_educational_program_priority
    ADD CONSTRAINT fk_aepp_application_id FOREIGN KEY (application_id) REFERENCES public.application(application_id) ON DELETE CASCADE;


--
-- Name: application_educational_program_priority fk_aepp_educational_program_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.application_educational_program_priority
    ADD CONSTRAINT fk_aepp_educational_program_id FOREIGN KEY (educational_program_id) REFERENCES public.educational_program(educational_program_id) ON DELETE CASCADE;


--
-- Name: application fk_application_admission_campaign_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.application
    ADD CONSTRAINT fk_application_admission_campaign_id FOREIGN KEY (admission_campaign_id) REFERENCES public.admission_campaign(admission_campaign_id);


--
-- Name: application fk_application_applicant_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.application
    ADD CONSTRAINT fk_application_applicant_id FOREIGN KEY (applicant_id) REFERENCES public.applicant(applicant_id);


--
-- Name: certificate fk_certificate_applicant_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.certificate
    ADD CONSTRAINT fk_certificate_applicant_id FOREIGN KEY (applicant_id) REFERENCES public.applicant(applicant_id);


--
-- Name: contract fk_contract_educational_program_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract
    ADD CONSTRAINT fk_contract_educational_program_id FOREIGN KEY (educational_program_id) REFERENCES public.educational_program(educational_program_id);


--
-- Name: contract fk_contract_order_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract
    ADD CONSTRAINT fk_contract_order_id FOREIGN KEY (order_id) REFERENCES public.enrollment_order(order_id);


--
-- Name: contract fk_contract_student_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract
    ADD CONSTRAINT fk_contract_student_id FOREIGN KEY (student_id) REFERENCES public.student(applicant_id);


--
-- Name: educational_program fk_educational_program_specialty_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.educational_program
    ADD CONSTRAINT fk_educational_program_specialty_id FOREIGN KEY (specialty_id) REFERENCES public.specialty(specialty_id);


--
-- Name: exam_result fk_exam_result_applicant_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exam_result
    ADD CONSTRAINT fk_exam_result_applicant_id FOREIGN KEY (applicant_id) REFERENCES public.applicant(applicant_id);


--
-- Name: passport fk_passport_personal_data_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.passport
    ADD CONSTRAINT fk_passport_personal_data_id FOREIGN KEY (personal_data_id) REFERENCES public.personal_data(personal_data_id);


--
-- Name: payment fk_payment_contract_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment
    ADD CONSTRAINT fk_payment_contract_id FOREIGN KEY (contract_id) REFERENCES public.contract(contract_id);


--
-- Name: personal_data fk_personal_data_applicant_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_data
    ADD CONSTRAINT fk_personal_data_applicant_id FOREIGN KEY (applicant_id) REFERENCES public.applicant(applicant_id);


--
-- Name: specialty fk_specialty_faculty_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.specialty
    ADD CONSTRAINT fk_specialty_faculty_id FOREIGN KEY (faculty_id) REFERENCES public.faculty(faculty_id);


--
-- Name: student fk_student_applicant_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.student
    ADD CONSTRAINT fk_student_applicant_id FOREIGN KEY (applicant_id) REFERENCES public.applicant(applicant_id);


--
-- Name: student_study_group fk_student_study_group_student_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.student_study_group
    ADD CONSTRAINT fk_student_study_group_student_id FOREIGN KEY (student_id) REFERENCES public.student(applicant_id);


--
-- Name: student_study_group fk_student_study_group_study_group_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.student_study_group
    ADD CONSTRAINT fk_student_study_group_study_group_id FOREIGN KEY (study_group_id) REFERENCES public.study_group(study_group_id);


--
-- Name: study_group fk_study_group_specialty_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.study_group
    ADD CONSTRAINT fk_study_group_specialty_id FOREIGN KEY (specialty_id) REFERENCES public.specialty(specialty_id);


--
-- PostgreSQL database dump complete
--

\unrestrict eK0I1sEDwx0fOFDY0YvXz8PfNMsWDoDvgBBUgeYCsHvIOuIBMa9yLznY6RJEteh

