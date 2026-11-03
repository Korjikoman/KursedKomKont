/*
  kursed — исправленная исходная модель для PostgreSQL 12 / DBeaver.
  Исходная модель: 20.10.2026. Исправлено: 02.11.2026. Кодировка: UTF-8.

  Запуск:
  1. Выберите подключение к существующей базе kursed.
  2. Откройте этот файл в SQL Editor и выполните весь скрипт
     (SQL Editor -> Execute SQL Script; обычно Alt+X).
  3. При ошибке выполните ROLLBACK; перед повторным запуском.

  Режим установки: чистая модель. Существующая public сохраняется.
  Скрипт не удаляет данные и объекты. Если объекты модели уже существуют,
  проверка остановит установку; это не миграция существующей схемы.
  Все обязательные изменения выполняются в одной транзакции.
  Нужны USAGE/CREATE на public, либо CREATE на БД для создания public.

  Сохранены 16 таблиц, 16 первичных ключей, 15 внешних ключей,
  13 последовательностей, 5 ENUM и исходные действия ON DELETE/UPDATE.
  Все имена таблиц и ссылки на последовательности дополнены схемой public.
  Исправлен ENUM study_form. Системные роли и их GRANT не изменяются.
  Из внешних ключей удалены DEFAULT nextval: передавайте существующий ID
  явно (либо NULL для необязательных связей). Типы и NULL/NOT NULL сохранены.
  student.student_id и attestat.attestat_id по исходной модели задаются явно.

  Роль bot создаётся только при её отсутствии. При нехватке CREATEROLE
  выводится NOTICE, установка таблиц продолжается. Существующая роль
  не изменяется. Пароль '123' сохранён из учебного исходника только для
  вновь создаваемой роли; права на таблицы автоматически не выдаются.

  Справка PostgreSQL 12:
  https://www.postgresql.org/docs/12/sql-createschema.html
  https://www.postgresql.org/docs/12/sql-createrole.html
  https://www.postgresql.org/docs/12/functions-sequence.html
*/

BEGIN;
SET LOCAL search_path = pg_catalog, public;
SET LOCAL lock_timeout = '5s';

DO $preflight$
DECLARE
    conflicts text;
BEGIN
    IF current_database() <> 'kursed' THEN
        RAISE EXCEPTION 'Выбрана БД %, требуется kursed.', current_database();
    END IF;
    SELECT string_agg(quote_ident(c.relname), ', ' ORDER BY c.relname)
    INTO conflicts
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = ANY (ARRAY['admission_campaign', 'applicant', 'application', 'attestat', 'contract', 'educational_program', 'enrollment_order', 'exam_result', 'faculty', 'passport', 'payment', 'personal_data', 'specialty', 'student', 'study_group', 'student_study_group', 'admission_campaign_admission_campaign_id_seq', 'applicant_applicant_id_seq', 'application_application_id_seq', 'contract_contract_id_seq', 'educational_program_educational_program_id_seq', 'enrollment_order_order_id_seq', 'exam_result_exam_result_id_seq', 'faculty_faculty_id_seq', 'passport_passport_id_seq', 'payment_payment_id_seq', 'personal_data_personal_data_id_seq', 'specialty_specialty_id_seq', 'study_group_study_group_id_seq', 'IX_Relationship23', 'IX_Relationship24', 'IX_Relationship46', 'IX_Relationship28', 'IX_Relationship33', 'IX_Relationship34', 'IX_Relationship35', 'IX_Relationship32', 'IX_Relationship25', 'IX_Relationship31', 'IX_Relationship36']);
    IF conflicts IS NOT NULL THEN
        RAISE EXCEPTION 'Объекты модели уже существуют в public: %. Нужна чистая модель; данные не удалены.', conflicts;
    END IF;

    SELECT string_agg(quote_ident(t.typname), ', ' ORDER BY t.typname)
    INTO conflicts
    FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public' AND t.typname = ANY (ARRAY['application_status', 'order_type', 'payment_method', 'payment_status', 'study_form', 'admission_campaign', 'applicant', 'application', 'attestat', 'contract', 'educational_program', 'enrollment_order', 'exam_result', 'faculty', 'passport', 'payment', 'personal_data', 'specialty', 'student', 'study_group', 'student_study_group']);
    IF conflicts IS NOT NULL THEN
        RAISE EXCEPTION 'Типы модели уже существуют в public: %. Установка остановлена.', conflicts;
    END IF;
END;
$preflight$;

CREATE SCHEMA IF NOT EXISTS public;

-- Create user data types section -------------------------------------------------
CREATE TYPE "public"."application_status" AS ENUM
( 'PROCESSED', 'CANCELLED', 'COMPLETED' );

CREATE TYPE "public"."order_type" AS ENUM
( 'ENROLLMENT', 'EXPULSION', 'TRANSFER' );

CREATE TYPE "public"."payment_method" AS ENUM
( 'CASH', 'CARD', 'BANK_TRANSFER' );

CREATE TYPE "public"."payment_status" AS ENUM
( 'PENDING', 'PAID', 'CANCELLED' );

CREATE TYPE "public"."study_form" AS ENUM
( 'in_person', 'in_absentia', 'mixed' );

-- Create sequences section -------------------------------------------------
CREATE SEQUENCE "public"."admission_campaign_admission_campaign_id_seq"
INCREMENT BY 1
START WITH 1
NO MAXVALUE
NO MINVALUE
CACHE 1;

CREATE SEQUENCE "public"."applicant_applicant_id_seq"
INCREMENT BY 1
START WITH 1
NO MAXVALUE
NO MINVALUE
CACHE 1;

CREATE SEQUENCE "public"."application_application_id_seq"
INCREMENT BY 1
START WITH 1
NO MAXVALUE
NO MINVALUE
CACHE 1;

CREATE SEQUENCE "public"."contract_contract_id_seq"
INCREMENT BY 1
START WITH 1
NO MAXVALUE
NO MINVALUE
CACHE 1;

CREATE SEQUENCE "public"."educational_program_educational_program_id_seq"
INCREMENT BY 1
START WITH 1
NO MAXVALUE
NO MINVALUE
CACHE 1;

CREATE SEQUENCE "public"."enrollment_order_order_id_seq"
INCREMENT BY 1
START WITH 1
NO MAXVALUE
NO MINVALUE
CACHE 1;

CREATE SEQUENCE "public"."exam_result_exam_result_id_seq"
INCREMENT BY 1
START WITH 1
NO MAXVALUE
NO MINVALUE
CACHE 1;

CREATE SEQUENCE "public"."faculty_faculty_id_seq"
INCREMENT BY 1
START WITH 1
NO MAXVALUE
NO MINVALUE
CACHE 1;

CREATE SEQUENCE "public"."passport_passport_id_seq"
INCREMENT BY 1
START WITH 1
NO MAXVALUE
NO MINVALUE
CACHE 1;

CREATE SEQUENCE "public"."payment_payment_id_seq"
INCREMENT BY 1
START WITH 1
NO MAXVALUE
NO MINVALUE
CACHE 1;

CREATE SEQUENCE "public"."personal_data_personal_data_id_seq"
INCREMENT BY 1
START WITH 1
NO MAXVALUE
NO MINVALUE
CACHE 1;

CREATE SEQUENCE "public"."specialty_specialty_id_seq"
INCREMENT BY 1
START WITH 1
NO MAXVALUE
NO MINVALUE
CACHE 1;

CREATE SEQUENCE "public"."study_group_study_group_id_seq"
INCREMENT BY 1
START WITH 1
NO MAXVALUE
NO MINVALUE
CACHE 1;

-- Create tables section -------------------------------------------------
-- Table public.admission_campaign
CREATE TABLE "public"."admission_campaign"
(
"admission_campaign_id" Bigint DEFAULT
nextval('public.admission_campaign_admission_campaign_id_seq'::regclass) NOT NULL,
"academic_year" Integer NOT NULL,
"start_date" Date NOT NULL,
"end_date" Date NOT NULL
)
WITH (
autovacuum_enabled=true);

ALTER TABLE "public"."admission_campaign" ADD CONSTRAINT "admission_campaign_pkey"
PRIMARY KEY ("admission_campaign_id");

-- Table public.applicant
CREATE TABLE "public"."applicant"
(
"applicant_id" Bigint DEFAULT nextval('public.applicant_applicant_id_seq'::regclass) NOT NULL,
"phone" Character varying(30) NOT NULL,
"email" Character varying(254) NOT NULL
)
WITH (
autovacuum_enabled=true);

ALTER TABLE "public"."applicant" ADD CONSTRAINT "applicant_pkey" PRIMARY KEY
("applicant_id");

-- Table public.application
CREATE TABLE "public"."application"
(
"application_id" Bigint DEFAULT nextval('public.application_application_id_seq'::regclass) NOT NULL,
"application_number" Character varying(50) NOT NULL,
"submission_date" Date NOT NULL,
"application_status" "public"."application_status" NOT NULL,
"admission_campaign_id" Bigint,
"applicant_id" Bigint
)
WITH (
autovacuum_enabled=true);

CREATE INDEX "IX_Relationship23" ON "public"."application" ("admission_campaign_id");

CREATE INDEX "IX_Relationship24" ON "public"."application" ("applicant_id");

ALTER TABLE "public"."application" ADD CONSTRAINT "application_pkey" PRIMARY KEY
("application_id");

-- Table public.attestat
CREATE TABLE "public"."attestat"
(
"attestat_id" Bigint NOT NULL,
"certificate_number" Character varying(100) NOT NULL,
"upload_date" Date NOT NULL,
"applicant_id" Bigint NOT NULL
)
WITH (
autovacuum_enabled=true);

CREATE INDEX "IX_Relationship46" ON "public"."attestat" ("applicant_id");

ALTER TABLE "public"."attestat" ADD CONSTRAINT "certificate_pkey" PRIMARY KEY
("attestat_id");

-- Table public.contract
CREATE TABLE "public"."contract"
(
"contract_id" Bigint DEFAULT nextval('public.contract_contract_id_seq'::regclass) NOT NULL,
"contract_number" Character varying(100) NOT NULL,
"conclusion_date" Date NOT NULL,
"amount" Numeric(12,2) NOT NULL,
"start_date" Date NOT NULL,
"end_date" Date NOT NULL,
"educational_program_id" Bigint,
"payment_id" Bigint,
"order_id" Bigint,
"student_id" Bigint
)
WITH (
autovacuum_enabled=true);

CREATE INDEX "IX_Relationship28" ON "public"."contract" ("student_id");

CREATE INDEX "IX_Relationship33" ON "public"."contract" ("educational_program_id");

CREATE INDEX "IX_Relationship34" ON "public"."contract" ("payment_id");

CREATE INDEX "IX_Relationship35" ON "public"."contract" ("order_id");

ALTER TABLE "public"."contract" ADD CONSTRAINT "contract_pkey" PRIMARY KEY
("contract_id");

-- Table public.educational_program
CREATE TABLE "public"."educational_program"
(
"educational_program_id" Bigint DEFAULT
nextval('public.educational_program_educational_program_id_seq'::regclass) NOT NULL,
"direction_code" Character varying(50) NOT NULL,
"program_name" Character varying(255) NOT NULL,
"study_duration" Integer NOT NULL,
"study_form" "public"."study_form" NOT NULL,
"specialty_id" Bigint
)
WITH (
autovacuum_enabled=true);

CREATE INDEX "IX_Relationship32" ON "public"."educational_program" ("specialty_id");

ALTER TABLE "public"."educational_program" ADD CONSTRAINT "educational_program_pkey"
PRIMARY KEY ("educational_program_id");

-- Table public.enrollment_order
CREATE TABLE "public"."enrollment_order"
(
"order_id" Bigint DEFAULT nextval('public.enrollment_order_order_id_seq'::regclass) NOT NULL,
"order_number" Character varying(100) NOT NULL,
"order_date" Date NOT NULL,
"order_type" "public"."order_type" NOT NULL
)
WITH (
autovacuum_enabled=true);

ALTER TABLE "public"."enrollment_order" ADD CONSTRAINT "enrollment_order_pkey"
PRIMARY KEY ("order_id");

-- Table public.exam_result
CREATE TABLE "public"."exam_result"
(
"exam_result_id" Bigint DEFAULT nextval('public.exam_result_exam_result_id_seq'::regclass) NOT
NULL,
"score" Integer NOT NULL,
"exam_year" Integer NOT NULL,
"exam_type" Character varying(100) NOT NULL,
"applicant_id" Bigint
)
WITH (
autovacuum_enabled=true);

CREATE INDEX "IX_Relationship25" ON "public"."exam_result" ("applicant_id");

ALTER TABLE "public"."exam_result" ADD CONSTRAINT "exam_result_pkey" PRIMARY KEY
("exam_result_id");

-- Table public.faculty
CREATE TABLE "public"."faculty"
(
"faculty_id" Bigint DEFAULT nextval('public.faculty_faculty_id_seq'::regclass) NOT NULL,
"faculty_name" Character varying(255) NOT NULL
)
WITH (
autovacuum_enabled=true);

ALTER TABLE "public"."faculty" ADD CONSTRAINT "faculty_pkey" PRIMARY KEY
("faculty_id");

-- Table public.passport
CREATE TABLE "public"."passport"
(
"passport_id" Bigint DEFAULT nextval('public.passport_passport_id_seq'::regclass) NOT NULL,
"series" Character varying(20) NOT NULL,
"passport_number" Character varying(30) NOT NULL,
"issued_by" Character varying(255) NOT NULL,
"issue_date" Date NOT NULL,
"subdivision_code" Character varying(20) NOT NULL,
"surname" Character varying(40) NOT NULL,
"name" Character varying(40) NOT NULL,
"otchestvo" Character varying(40),
"birth_date" Date NOT NULL,
"address" Character varying(500),
"personal_data_id" Bigint NOT
NULL,
"applicant_id" Bigint NOT NULL
)
WITH (
autovacuum_enabled=true);

ALTER TABLE "public"."passport" ADD CONSTRAINT "passport_pkey" PRIMARY KEY
("passport_id","personal_data_id","applicant_id");

-- Table public.payment
CREATE TABLE "public"."payment"
(
"payment_id" Bigint DEFAULT nextval('public.payment_payment_id_seq'::regclass) NOT NULL,
"payment_date" Date NOT NULL,
"amount" Numeric(12,2) NOT NULL,
"payment_status" "public"."payment_status" NOT NULL,
"payment_method" "public"."payment_method" NOT NULL
)
WITH (
autovacuum_enabled=true);

ALTER TABLE "public"."payment" ADD CONSTRAINT "payment_pkey" PRIMARY KEY
("payment_id");

-- Table public.personal_data
CREATE TABLE "public"."personal_data"
(
"personal_data_id" Bigint DEFAULT nextval('public.personal_data_personal_data_id_seq'::regclass) NOT
NULL,
"snils" Character varying(20) NOT NULL,
"applicant_id" Bigint NOT NULL
)
WITH (
autovacuum_enabled=true);

ALTER TABLE "public"."personal_data" ADD CONSTRAINT "personal_data_pkey" PRIMARY
KEY ("personal_data_id","applicant_id");

-- Table public.specialty
CREATE TABLE "public"."specialty"
(
"specialty_id" Bigint DEFAULT nextval('public.specialty_specialty_id_seq'::regclass) NOT NULL,
"specialty_code" Character varying(50) NOT NULL,
"faculty_id" Bigint
)
WITH (
autovacuum_enabled=true);

CREATE INDEX "IX_Relationship31" ON "public"."specialty" ("faculty_id");

ALTER TABLE "public"."specialty" ADD CONSTRAINT "specialty_pkey" PRIMARY KEY
("specialty_id");

-- Table public.student
CREATE TABLE "public"."student"
(
"student_id" Bigint NOT NULL,
"record_book_number" Character varying(50) NOT NULL,
"enrollment_date" Date NOT NULL,
"applicant_id" Bigint
)
WITH (
autovacuum_enabled=true);

CREATE INDEX "IX_Relationship36" ON "public"."student" ("applicant_id");

ALTER TABLE "public"."student" ADD CONSTRAINT "student_pkey" PRIMARY KEY
("student_id");

-- Table public.study_group
CREATE TABLE "public"."study_group"
(
"study_group_id" Bigint DEFAULT nextval('public.study_group_study_group_id_seq'::regclass) NOT
NULL,
"group_name" Character varying(100) NOT NULL,
"course" Integer NOT NULL,
"admission_year" Integer NOT NULL
)
WITH (
autovacuum_enabled=true);

ALTER TABLE "public"."study_group" ADD CONSTRAINT "study_group_pkey" PRIMARY KEY
("study_group_id");

-- Table student_study_group
CREATE TABLE "public"."student_study_group"
(
"student_id" Bigint NOT NULL,
"study_group_id" Bigint NOT
NULL
)
WITH (
autovacuum_enabled=true);

ALTER TABLE "public"."student_study_group" ADD CONSTRAINT "PK_student_study_group" PRIMARY
KEY ("student_id","study_group_id");

-- Create foreign keys (relationships) section -------------------------------------------------
ALTER TABLE "public"."application"
ADD CONSTRAINT "Relationship23"
FOREIGN KEY ("admission_campaign_id")
REFERENCES "public"."admission_campaign" ("admission_campaign_id")
ON DELETE NO ACTION
ON UPDATE NO ACTION;

ALTER TABLE "public"."application"
ADD CONSTRAINT "Relationship24"
FOREIGN KEY ("applicant_id")
REFERENCES "public"."applicant" ("applicant_id")
ON DELETE RESTRICT
ON UPDATE RESTRICT;

ALTER TABLE "public"."exam_result"
ADD CONSTRAINT "Relationship25"
FOREIGN KEY ("applicant_id")
REFERENCES "public"."applicant" ("applicant_id")
ON DELETE RESTRICT
ON UPDATE RESTRICT;

ALTER TABLE "public"."personal_data"
ADD CONSTRAINT "Relationship26"
FOREIGN KEY ("applicant_id")
REFERENCES "public"."applicant" ("applicant_id")
ON DELETE CASCADE
ON UPDATE RESTRICT;

ALTER TABLE "public"."passport"
ADD CONSTRAINT "Relationship27"
FOREIGN KEY ("personal_data_id", "applicant_id")
REFERENCES "public"."personal_data" ("personal_data_id", "applicant_id")
ON DELETE CASCADE
ON UPDATE RESTRICT;

ALTER TABLE "public"."contract"
ADD CONSTRAINT "Relationship28"
FOREIGN KEY ("student_id")
REFERENCES "public"."student" ("student_id")
ON DELETE RESTRICT
ON UPDATE RESTRICT;

ALTER TABLE "public"."specialty"
ADD CONSTRAINT "Relationship31"
FOREIGN KEY ("faculty_id")
REFERENCES "public"."faculty" ("faculty_id")
ON DELETE RESTRICT
ON UPDATE RESTRICT;

ALTER TABLE "public"."educational_program"
ADD CONSTRAINT "Relationship32"
FOREIGN KEY ("specialty_id")
REFERENCES "public"."specialty" ("specialty_id")
ON DELETE RESTRICT
ON UPDATE RESTRICT;

ALTER TABLE "public"."contract"
ADD CONSTRAINT "Relationship33"
FOREIGN KEY ("educational_program_id")
REFERENCES "public"."educational_program" ("educational_program_id")
ON DELETE RESTRICT
ON UPDATE RESTRICT;

ALTER TABLE "public"."contract"
ADD CONSTRAINT "Relationship34"
FOREIGN KEY ("payment_id")
REFERENCES "public"."payment" ("payment_id")
ON DELETE RESTRICT
ON UPDATE RESTRICT;

ALTER TABLE "public"."contract"
ADD CONSTRAINT "Relationship35"
FOREIGN KEY ("order_id")
REFERENCES "public"."enrollment_order" ("order_id")
ON DELETE RESTRICT
ON UPDATE RESTRICT;

ALTER TABLE "public"."student"
ADD CONSTRAINT "Relationship36"
FOREIGN KEY ("applicant_id")
REFERENCES "public"."applicant" ("applicant_id")
ON DELETE RESTRICT
ON UPDATE RESTRICT;

ALTER TABLE "public"."student_study_group"
ADD CONSTRAINT "Relationship43"
FOREIGN KEY ("student_id")
REFERENCES "public"."student" ("student_id")
ON DELETE CASCADE
ON UPDATE RESTRICT;

ALTER TABLE "public"."student_study_group"
ADD CONSTRAINT "Relationship45"
FOREIGN KEY ("study_group_id")
REFERENCES "public"."study_group" ("study_group_id")
ON DELETE RESTRICT
ON UPDATE RESTRICT;

ALTER TABLE "public"."attestat"
ADD CONSTRAINT "Relationship46"
FOREIGN KEY ("applicant_id")
REFERENCES "public"."applicant" ("applicant_id")
ON DELETE RESTRICT
ON UPDATE RESTRICT;

-- Associating sequence with table column section section ------------------------------
ALTER SEQUENCE "public"."admission_campaign_admission_campaign_id_seq" OWNED BY
"public"."admission_campaign"."admission_campaign_id";

ALTER SEQUENCE "public"."applicant_applicant_id_seq" OWNED BY
"public"."applicant"."applicant_id";

ALTER SEQUENCE "public"."application_application_id_seq" OWNED BY
"public"."application"."application_id";

ALTER SEQUENCE "public"."contract_contract_id_seq" OWNED BY
"public"."contract"."contract_id";

ALTER SEQUENCE "public"."educational_program_educational_program_id_seq" OWNED BY
"public"."educational_program"."educational_program_id";

ALTER SEQUENCE "public"."enrollment_order_order_id_seq" OWNED BY
"public"."enrollment_order"."order_id";

ALTER SEQUENCE "public"."exam_result_exam_result_id_seq" OWNED BY
"public"."exam_result"."exam_result_id";

ALTER SEQUENCE "public"."faculty_faculty_id_seq" OWNED BY "public"."faculty"."faculty_id";

ALTER SEQUENCE "public"."passport_passport_id_seq" OWNED BY
"public"."passport"."passport_id";

ALTER SEQUENCE "public"."payment_payment_id_seq" OWNED BY
"public"."payment"."payment_id";

ALTER SEQUENCE "public"."personal_data_personal_data_id_seq" OWNED BY
"public"."personal_data"."personal_data_id";

ALTER SEQUENCE "public"."specialty_specialty_id_seq" OWNED BY
"public"."specialty"."specialty_id";

ALTER SEQUENCE "public"."study_group_study_group_id_seq" OWNED BY
"public"."study_group"."study_group_id";

-- Необязательная роль приложения. Нет GRANT на встроенные роли PostgreSQL.
DO $bot_role$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bot') THEN
        BEGIN
            CREATE ROLE bot LOGIN PASSWORD '123'
                NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
        EXCEPTION
            WHEN insufficient_privilege THEN
                RAISE NOTICE 'Роль bot не создана: нет CREATEROLE. Таблицы установлены; при необходимости роль создаст администратор.';
            WHEN duplicate_object THEN
                RAISE NOTICE 'Роль bot уже создана другим подключением; её параметры сохранены.';
        END;
    ELSE
        RAISE NOTICE 'Роль bot уже существует; её пароль и параметры сохранены.';
    END IF;
END;
$bot_role$;

COMMIT;

-- Итог установки. После выполнения обновите public -> Tables в DBeaver (F5).
SELECT current_database() AS database_name,
       'Модель успешно установлена: 16 таблиц, 15 внешних ключей' AS result;
