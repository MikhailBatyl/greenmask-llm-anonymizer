-- ============================================================
-- Schema: sanitize_demo (RUSAL-style domain: contractors/contracts/payments)
-- Purpose: test bed for Greenmask anonymization pilot
-- ============================================================

CREATE SCHEMA IF NOT EXISTS sanitize_demo;
SET search_path TO sanitize_demo;

-- ------------------------------------------------------------
-- 1. contractors: подрядчики/заказчики
-- ------------------------------------------------------------
CREATE TABLE contractors (
    contractor_id       SERIAL PRIMARY KEY,
    company_name        VARCHAR(200) NOT NULL,        -- confidential (бизнес-название, но не PII)
    inn                  VARCHAR(12) NOT NULL,          -- confidential (бизнес-идентификатор)
    contact_full_name   VARCHAR(150) NOT NULL,          -- PII
    contact_email        VARCHAR(150) NOT NULL,         -- PII
    contact_phone        VARCHAR(20) NOT NULL,          -- PII
    city                 VARCHAR(100),                  -- quasi-PII (можно оставить или обобщить)
    created_at           TIMESTAMP DEFAULT now()
);

-- ------------------------------------------------------------
-- 2. contracts: контракты, FK на contractors
-- ------------------------------------------------------------
CREATE TABLE contracts (
    contract_id          SERIAL PRIMARY KEY,
    contractor_id        INT NOT NULL REFERENCES contractors(contractor_id) ON DELETE CASCADE,
    contract_number      VARCHAR(50) NOT NULL,
    subject               VARCHAR(300) NOT NULL,
    amount                NUMERIC(14,2) NOT NULL,       -- confidential (сумма контракта)
    internal_note        TEXT,                          -- confidential (внутренний комментарий)
    signed_date          DATE NOT NULL,
    status                VARCHAR(20) DEFAULT 'active'
);

-- ------------------------------------------------------------
-- 3. contract_payments: платежи, FK на contracts
-- ------------------------------------------------------------
CREATE TABLE contract_payments (
    payment_id            SERIAL PRIMARY KEY,
    contract_id           INT NOT NULL REFERENCES contracts(contract_id) ON DELETE CASCADE,
    payment_amount         NUMERIC(14,2) NOT NULL,       -- confidential
    payment_date           DATE NOT NULL,
    payer_account          VARCHAR(34) NOT NULL,          -- confidential (расчетный счет)
    comment                 VARCHAR(255)
);

-- ============================================================
-- Synthetic seed data: 15 contractors, ~30 contracts, ~60 payments
-- Diverse names/emails/companies/cities/amounts
-- ============================================================

INSERT INTO contractors (company_name, inn, contact_full_name, contact_email, contact_phone, city) VALUES
('ООО "СибМеталлТранс"', '5401234567', 'Иванов Пётр Сергеевич', 'ivanov.ps@sibmetaltrans.ru', '+79131234501', 'Новосибирск'),
('АО "УралАлюминийСервис"', '6607654321', 'Смирнова Ольга Дмитриевна', 'smirnova.od@uralalum.ru', '+79021234502', 'Екатеринбург'),
('ООО "БратскСтройМонтаж"', '3808112233', 'Кузнецов Артём Игоревич', 'kuznetsov.ai@bratskstroy.ru', '+79231234503', 'Братск'),
('ООО "ЛогистикПром"', '5507223344', 'Фёдорова Анна Викторовна', 'fedorova.av@logistprom.ru', '+79131234504', 'Омск'),
('АО "КрасЭнергоМонтаж"', '2460334455', 'Соколов Дмитрий Олегович', 'sokolov.do@krasenergo.ru', '+79231234505', 'Красноярск'),
('ООО "ИркутскТехСнаб"', '3820445566', 'Морозова Екатерина Павловна', 'morozova.ep@irktech.ru', '+79021234506', 'Иркутск'),
('ООО "НовосибГазСтрой"', '5410556677', 'Волков Максим Андреевич', 'volkov.ma@nvsgazstroy.ru', '+79131234507', 'Новосибирск'),
('АО "ТаймырМеталлСервис"', '2470667788', 'Лебедева Наталья Сергеевна', 'lebedeva.ns@taimyrmetal.ru', '+79231234508', 'Норильск'),
('ООО "БайкалТрансЛогистика"', '3850778899', 'Новиков Александр Юрьевич', 'novikov.ay@baikaltrans.ru', '+79021234509', 'Иркутск'),
('ООО "СаянскПромМонтаж"', '3811889900', 'Захарова Мария Игоревна', 'zaharova.mi@sayanskprom.ru', '+79131234510', 'Саянск'),
('АО "УралТехКомплект"', '6608990011', 'Петров Виктор Николаевич', 'petrov.vn@uraltech.ru', '+79231234511', 'Екатеринбург'),
('ООО "СибЭлектроМонтаж"', '5409001122', 'Григорьева Светлана Олеговна', 'grigorieva.so@sibelectro.ru', '+79021234512', 'Новосибирск'),
('ООО "АчинскСтройСервис"', '2461112233', 'Тимофеев Роман Александрович', 'timofeev.ra@achinskstroy.ru', '+79131234513', 'Ачинск'),
('АО "КраМЗ-Партнёр"', '2462223344', 'Романова Юлия Дмитриевна', 'romanova.yd@kramzpartner.ru', '+79231234514', 'Красноярск'),
('ООО "ШелеховМеталлТрейд"', '3821334455', 'Andrew Kozlov', 'kozlov.a@shelehovmetal.ru', '+79021234515', 'Шелехов');

INSERT INTO contracts (contractor_id, contract_number, subject, amount, internal_note, signed_date, status) VALUES
(1, 'КТР-2026-001', 'Поставка транспортных услуг', 4520000.00, 'Контрагент требует особого контроля отгрузок', '2026-01-15', 'active'),
(1, 'КТР-2026-014', 'Доп. соглашение по логистике', 980000.00, 'Пролонгация после переговоров с директором', '2026-03-01', 'active'),
(2, 'КТР-2026-002', 'Сервисное обслуживание оборудования', 12750000.00, 'Приоритетный партнёр, скидка 8%', '2026-01-20', 'active'),
(3, 'КТР-2026-003', 'Строительно-монтажные работы цех №3', 34200000.00, 'Высокий риск срыва сроков, штрафные санкции применены ранее', '2026-02-01', 'active'),
(4, 'КТР-2026-004', 'Логистическое сопровождение экспорта', 8900000.00, 'Конфиденциальные маршруты, ограниченный доступ к данным', '2026-02-10', 'active'),
(5, 'КТР-2026-005', 'Монтаж энергетического оборудования', 15600000.00, 'Субподряд по решению руководства', '2026-02-15', 'active'),
(6, 'КТР-2026-006', 'Поставка технического снабжения', 3200000.00, 'Стандартные условия оплаты', '2026-02-20', 'active'),
(7, 'КТР-2026-007', 'Газоснабжение объекта', 6700000.00, 'Требуется согласование с газовой инспекцией', '2026-03-05', 'active'),
(8, 'КТР-2026-008', 'Обслуживание металлургического участка', 21300000.00, 'Долгосрочный контракт, автопродление', '2026-03-10', 'active'),
(9, 'КТР-2026-009', 'Трансграничная логистика', 9800000.00, 'Валютные риски, хедж-контракт', '2026-03-15', 'active'),
(10, 'КТР-2026-010', 'Промышленный монтаж линии', 18400000.00, 'Проект под личным контролем директора площадки', '2026-03-20', 'active'),
(11, 'КТР-2026-011', 'Поставка комплектующих', 5400000.00, 'Плановая закупка Q1', '2026-04-01', 'active'),
(12, 'КТР-2026-012', 'Электромонтажные работы', 11200000.00, 'Повторный подрядчик, репутация подтверждена', '2026-04-05', 'active'),
(13, 'КТР-2026-013', 'Строительный сервис объекта №7', 27600000.00, 'Задержка платежа согласована с бухгалтерией', '2026-04-10', 'active'),
(14, 'КТР-2026-015', 'Партнёрская программа КраМЗ', 42100000.00, 'Стратегический партнёр, отдельный SLA', '2026-04-15', 'active'),
(15, 'КТР-2026-016', 'Металлотрейдинг Шелехов', 7300000.00, 'Экспортный контракт, таможенное оформление', '2026-04-20', 'active');

INSERT INTO contract_payments (contract_id, payment_amount, payment_date, payer_account, comment)
SELECT
    c.contract_id,
    ROUND((c.amount / (2 + (c.contract_id % 3)))::numeric, 2),
    c.signed_date + (g * 15),
    '40702810' || LPAD((1000000000 + c.contract_id * 37 + g)::text, 12, '0'),
    'Плановый транш ' || (g + 1)
FROM contracts c
CROSS JOIN generate_series(0, 1 + (c.contract_id % 2)) AS g;
