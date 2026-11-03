
BEGIN;
SET LOCAL search_path = public, pg_catalog;
SET LOCAL client_min_messages = notice;

-- 1. ТЕСТОВЫЕ ДАННЫЕ.
-- Иванов: начислено 20 000, оплачено 4 000, долг сегодня 6 000;
-- ещё 10 000 со сроком через месяц пока не входят в текущий долг.
-- Петров: начислено и оплачено 10 000; нет паспорта и СНИЛС.
CREATE TEMP TABLE demo_before ON COMMIT DROP AS
SELECT kk_paid_tuition_total() AS paid;
CREATE TEMP TABLE demo_results (
    test text, expected text, actual text, passed boolean
) ON COMMIT DROP;

INSERT INTO admission_campaign(admission_campaign_id, academic_year, start_date, end_date)
VALUES (-93001, EXTRACT(YEAR FROM CURRENT_DATE)::int,
        date_trunc('year', CURRENT_DATE)::date,
        (date_trunc('year', CURRENT_DATE) + interval '1 year - 1 day')::date);
INSERT INTO specialty(specialty_id, specialty_code) VALUES (-93001, 'DEMO-09.03.04');
INSERT INTO educational_program(educational_program_id, direction_code, program_name,
                                study_duration, study_form, specialty_id)
VALUES (-93001, 'DEMO-09.03.04', 'ТЕСТ: Программная инженерия', 4, 'in_person', -93001);
INSERT INTO applicant(applicant_id, phone, email) VALUES
(-93001, '+70000000001', 'ivanov@example.test'),
(-93002, '+70000000002', 'petrov@example.test');
INSERT INTO student(student_id, record_book_number, enrollment_date, applicant_id) VALUES
(-93001, 'DEMO-001', CURRENT_DATE, -93001),
(-93002, 'DEMO-002', CURRENT_DATE, -93002);
INSERT INTO personal_data(personal_data_id, snils, applicant_id)
VALUES (-93001, '000-000-000 01', -93001);
INSERT INTO passport(passport_id, series, passport_number, issued_by, issue_date,
    subdivision_code, surname, name, birth_date, personal_data_id, applicant_id)
VALUES (-93001, '0000', '000001', 'Тестовое подразделение', DATE '2020-01-01',
        '000-000', 'Иванов', 'Иван', DATE '2002-01-01', -93001, -93001);
INSERT INTO exam_result(exam_result_id, applicant_id, score, exam_year, exam_type)
SELECT -93000 - row_number() OVER (), applicant_id, score,
       EXTRACT(YEAR FROM CURRENT_DATE)::int, subject
FROM (VALUES (-93001, 80, 'Математика'), (-93001, 85, 'Русский язык'),
             (-93001, 90, 'Информатика'), (-93002, 70, 'Математика'),
             (-93002, 75, 'Русский язык'), (-93002, 80, 'Информатика'))
     AS x(applicant_id, score, subject);
INSERT INTO direction_choice(direction_choice_id, applicant_id,
    educational_program_id, admission_campaign_id, priority)
VALUES (-93001, -93001, -93001, -93001, 1), (-93002, -93002, -93001, -93001, 1);
INSERT INTO contract(contract_id, contract_number, conclusion_date, amount,
                     start_date, end_date, educational_program_id, student_id)
VALUES (-93001, 'DEMO-DEBT', CURRENT_DATE - 30, 20000,
        CURRENT_DATE - 30, CURRENT_DATE + 180, -93001, -93001),
       (-93002, 'DEMO-PAID', CURRENT_DATE - 30, 10000,
        CURRENT_DATE - 30, CURRENT_DATE + 180, -93001, -93002);
INSERT INTO payment_schedule(payment_schedule_id, contract_id, installment_no,
                              period_start, period_end, due_date, amount)
VALUES (-93001, -93001, 1, CURRENT_DATE - 30, CURRENT_DATE - 1, CURRENT_DATE - 10, 10000),
       (-93002, -93001, 2, CURRENT_DATE, CURRENT_DATE + 60, CURRENT_DATE + 30, 10000),
       (-93003, -93002, 1, CURRENT_DATE - 30, CURRENT_DATE - 1, CURRENT_DATE - 10, 10000);
INSERT INTO payment(payment_id, payment_date, amount, payment_status, payment_method)
VALUES (-93001, CURRENT_DATE - 5, 4000, 'PAID', 'CARD'),
       (-93002, CURRENT_DATE - 5, 10000, 'PAID', 'BANK_TRANSFER'),
       (-93003, CURRENT_DATE, 7000, 'PENDING', 'CARD');
INSERT INTO payment_allocation(payment_id, payment_schedule_id, amount)
VALUES (-93001, -93001, 4000), (-93002, -93003, 10000), (-93003, -93002, 7000);

-- 2. СОЗДАНИЕ ЗАЯВЛЕНИЙ: функция возвращает ID и создаёт состояние NEW.
CREATE TEMP TABLE demo_applications ON COMMIT DROP AS
SELECT kk_create_application(-93001, -93001, 'DEMO-001', CURRENT_DATE) AS id
UNION ALL
SELECT kk_create_application(-93002, -93001, 'DEMO-002', CURRENT_DATE);
SELECT a.application_number, a.application_id, s.workflow_status AS "Ожидается NEW"
FROM demo_applications d JOIN application a ON a.application_id = d.id
JOIN application_state s USING (application_id) ORDER BY a.application_number;
INSERT INTO demo_results
SELECT 'kk_create_application: два заявления со статусом NEW', '2', count(*)::text,
       count(*) = 2
FROM demo_applications d JOIN application_state s ON s.application_id = d.id
WHERE s.workflow_status = 'NEW';

-- 3. ФИНАНСОВЫЕ ФУНКЦИИ. Ожидаемое и фактическое значения рядом.
INSERT INTO demo_results
SELECT test, expected::text, actual::text, expected = actual
FROM (VALUES
 ('kk_period_debt: остаток первого периода', 6000, kk_period_debt(-93001)),
 ('kk_period_overdue_debt: просрочено', 6000, kk_period_overdue_debt(-93001)),
 ('kk_period_overdue_debt: в день срока ещё нет просрочки', 0,
     kk_period_overdue_debt(-93001, CURRENT_DATE - 10)),
 ('kk_period_debt: PENDING не считается оплатой', 10000, kk_period_debt(-93002)),
 ('kk_period_overdue_debt: будущий период', 0, kk_period_overdue_debt(-93002)),
 ('kk_contract_accrued: все начисления', 20000, kk_contract_accrued(-93001)),
 ('kk_contract_paid: подтверждённые оплаты', 4000, kk_contract_paid(-93001)),
 ('kk_contract_debt: только наступившие сроки', 6000, kk_contract_debt(-93001)),
 ('kk_contract_debt: полностью оплаченный договор', 0, kk_contract_debt(-93002)),
 ('kk_paid_tuition_total: прирост PAID, без PENDING', 14000,
     kk_paid_tuition_total() - (SELECT paid FROM demo_before))
) AS x(test, expected, actual);
SELECT test AS "Функция", expected AS "Ожидалось", actual AS "Получено",
       CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS "Результат"
FROM demo_results WHERE test LIKE 'kk_%' AND test NOT LIKE 'kk_create%';

-- 4. СПИСКИ. Отбираем только наших студентов / программу / кампанию.
-- Ожидается Иванов с долгом 6 000; полностью оплатившего Петрова в списке нет.
SELECT * FROM kk_debtors(CURRENT_DATE, -93001);
SELECT * FROM kk_students_unpaid_semester(CURRENT_DATE - 30, CURRENT_DATE + 60,
                                         CURRENT_DATE, -93001);
-- Ожидается Петров (-93002): не хватает паспорта и СНИЛС, экзамены есть.
SELECT * FROM kk_students_missing_documents()
WHERE student_id IN (-93001, -93002);
-- Одно место, минимум 200: проходит Иванов с 255, Петров с 225 не проходит по месту.
SELECT * FROM kk_specialty_admission_list(-93001, 200, 1, 1, -93001);
-- Единственная специальность: 2 абитуриента, 2 первых приоритета, вес 2.
SELECT * FROM kk_top_specialties(5, -93001);

INSERT INTO demo_results
SELECT test, expected, actual, expected = actual FROM (VALUES
 ('kk_debtors: только Иванов', '-93001',
  (SELECT string_agg(student_id::text, ',' ORDER BY student_id)
   FROM kk_debtors(CURRENT_DATE, -93001))),
 ('kk_students_unpaid_semester: только Иванов', '-93001',
  (SELECT string_agg(student_id::text, ',' ORDER BY student_id)
   FROM kk_students_unpaid_semester(CURRENT_DATE - 30, CURRENT_DATE + 60,
                                    CURRENT_DATE, -93001))),
 ('kk_students_missing_documents: Петров, паспорт и СНИЛС', '-93002:Паспорт,СНИЛС',
  (SELECT string_agg(student_id || ':' || array_to_string(missing_documents, ','),
                     ';' ORDER BY student_id)
   FROM kk_students_missing_documents() WHERE student_id IN (-93001, -93002))),
 ('kk_specialty_admission_list: одно место, победитель 255 баллов', '-93001:255',
  (SELECT string_agg(applicant_id || ':' || total_score, ',' ORDER BY rank_no)
   FROM kk_specialty_admission_list(-93001, 200, 1, 1, -93001))),
 ('kk_top_specialties: первое место, 2 человека, 2 первых приоритета', '1:2:2:2.000000',
  (SELECT rank_no || ':' || applicants_count || ':' || first_priority_count || ':' || priority_score
   FROM kk_top_specialties(5, -93001)))
) AS x(test, expected, actual);

-- 5. ТРИГГЕРЫ. Намеренные ошибки перехватываются, скрипт продолжает работу.
-- Помощник существует только в этом соединении и откатится вместе с тестами.
CREATE FUNCTION pg_temp.demo_reject(p_test text, p_sql text, p_message text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_actual text := 'Запрос выполнен без ошибки'; v_ok boolean := false;
BEGIN
    BEGIN
        EXECUTE p_sql;
        -- Даже если триггер сломан, пробное изменение нужно отменить.
        RAISE EXCEPTION USING ERRCODE = 'ZX001', MESSAGE = 'Нет ошибки триггера';
    EXCEPTION WHEN SQLSTATE 'ZX001' THEN NULL;
        WHEN OTHERS THEN
            v_actual := SQLERRM;
            v_ok := SQLSTATE = 'P0001' AND starts_with(SQLERRM, p_message);
    END;
    INSERT INTO demo_results VALUES (p_test, p_message, v_actual, v_ok);
    RAISE NOTICE '% | % | %', CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END, p_test, v_actual;
END;
$$;

SELECT pg_temp.demo_reject('Триггер: даты кампании',
 'UPDATE admission_campaign SET start_date = end_date + 1 WHERE admission_campaign_id = -93001',
 'Admission campaign start_date cannot be after end_date');
SELECT pg_temp.demo_reject('Триггер: заявление вне кампании',
 'UPDATE application SET submission_date = (SELECT end_date + 1 FROM admission_campaign WHERE admission_campaign_id = -93001) WHERE application_id IN (SELECT id FROM demo_applications)',
 'Submission date');
SELECT pg_temp.demo_reject('Триггер: 150 баллов запрещены',
 'UPDATE exam_result SET score = 150 WHERE applicant_id = -93001',
 'Exam score must be between 0 and 100');
SELECT pg_temp.demo_reject('Триггер: отрицательная сумма договора',
 'UPDATE contract SET amount = -100 WHERE contract_id = -93001',
 'Contract amount must be positive');
SELECT pg_temp.demo_reject('Триггер: нулевой платёж',
 'UPDATE payment SET amount = 0 WHERE payment_id = -93001',
 'Payment amount must be positive');
SELECT pg_temp.demo_reject('Триггер: нельзя распределить больше платежа',
 'UPDATE payment_allocation SET amount = 5000 WHERE payment_id = -93001',
 'Распределение превышает сумму платежа');
SELECT pg_temp.demo_reject('Триггер: начисление не может стать меньше оплаты',
 'UPDATE payment_schedule SET amount = 3000 WHERE payment_schedule_id = -93001',
 'Начисление 3000.00 меньше уже распределённой суммы');

-- 6. АУДИТ: четыре AFTER-триггера записали новые заявления, состояния, договоры, оплаты.
INSERT INTO demo_results
SELECT 'Аудит INSERT: ' || table_name, expected::text, actual::text, expected = actual
FROM (VALUES ('application', 2), ('application_state', 2), ('contract', 2), ('payment', 3))
     AS t(table_name, expected)
CROSS JOIN LATERAL (
 SELECT count(*) AS actual FROM audit_log a
 WHERE a.table_name = t.table_name AND a.operation = 'INSERT'
   AND CASE WHEN t.table_name IN ('application', 'application_state')
       THEN a.record_key IN (SELECT id::text FROM demo_applications)
       ELSE a.record_key IN ('-93001', '-93002', '-93003') END
) AS x;
-- UPDATE и DELETE также оставляют старые/новые значения.
UPDATE application_state SET workflow_status = 'SUBMITTED'
WHERE application_id = (SELECT min(id) FROM demo_applications);
DELETE FROM payment_allocation WHERE payment_id = -93003;
DELETE FROM payment WHERE payment_id = -93003;
INSERT INTO demo_results
SELECT 'Аудит UPDATE: NEW -> SUBMITTED', '1', count(*)::text, count(*) = 1
FROM audit_log WHERE table_name = 'application_state' AND operation = 'UPDATE'
  AND record_key = (SELECT min(id)::text FROM demo_applications)
  AND old_data->>'workflow_status' = 'NEW' AND new_data->>'workflow_status' = 'SUBMITTED';
INSERT INTO demo_results
SELECT 'Аудит DELETE: старый платёж сохранён', '1', count(*)::text, count(*) = 1
FROM audit_log WHERE table_name = 'payment' AND operation = 'DELETE'
  AND record_key = '-93003' AND old_data->>'amount' = '7000.00' AND new_data IS NULL;
SELECT table_name, operation, record_key, old_data, new_data FROM audit_log
WHERE (table_name IN ('application', 'application_state')
       AND record_key IN (SELECT id::text FROM demo_applications))
   OR (table_name IN ('contract', 'payment') AND record_key IN ('-93001', '-93002', '-93003'))
ORDER BY audit_id;

-- 7. ИТОГ: у каждой строки ожидается PASS.
SELECT test AS "Проверка", expected AS "Ожидалось", actual AS "Получено",
       CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS "Результат"
FROM demo_results ORDER BY test;
SELECT count(*) AS "Всего проверок", count(*) FILTER (WHERE passed) AS "PASS",
       count(*) FILTER (WHERE passed IS NOT TRUE) AS "FAIL" FROM demo_results;
DO $$
DECLARE r record;
BEGIN
    FOR r IN SELECT * FROM demo_results ORDER BY test LOOP
        RAISE NOTICE '% | % | ожидалось: % | получено: %',
            CASE WHEN r.passed THEN 'PASS' ELSE 'FAIL' END, r.test, r.expected, r.actual;
    END LOOP;
END;
$$;

ROLLBACK;
SELECT 'Готово: тестовые записи удалены откатом; скрипт можно запустить снова.' AS "Итог";
