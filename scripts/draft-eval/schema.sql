-- Fixture for scripts/eval-sql-draft.sh: a small but realistic catalogue the
-- "Describe a query" drafter is graded against. Structure only, plus a few
-- rows so a grader can tell an empty answer from a wrong one; the drafter
-- never sees a row.
--
-- Loaded into its own database (pharos_draft_eval) so schema names can be
-- the ordinary ones a user has: public, sales, hr.

DROP SCHEMA IF EXISTS sales CASCADE;
DROP SCHEMA IF EXISTS hr CASCADE;
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
CREATE SCHEMA sales;
CREATE SCHEMA hr;

-- ---------------------------------------------------------------- public
CREATE TABLE public.countries (
    code char(2) PRIMARY KEY,
    name text NOT NULL,
    region text NOT NULL
);
COMMENT ON TABLE public.countries IS 'ISO 3166 countries';

CREATE TABLE public.currencies (
    code char(3) PRIMARY KEY,
    name text NOT NULL,
    symbol text
);

CREATE TABLE public.audit_log (
    id bigserial PRIMARY KEY,
    actor text NOT NULL,
    action text NOT NULL,
    target_table text NOT NULL,
    target_id bigint,
    happened_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.audit_log IS 'who changed what, and when';

CREATE TABLE public.app_settings (
    key text PRIMARY KEY,
    value text NOT NULL
);

-- ---------------------------------------------------------------- hr
CREATE TABLE hr.departments (
    id serial PRIMARY KEY,
    name text NOT NULL UNIQUE,
    parent_id int REFERENCES hr.departments(id),
    country_code char(2) REFERENCES public.countries(code)
);

CREATE TYPE hr.employment_type AS ENUM ('full_time', 'part_time', 'contractor', 'intern');

CREATE TABLE hr.employees (
    id serial PRIMARY KEY,
    first_name text NOT NULL,
    last_name text NOT NULL,
    email text NOT NULL UNIQUE,
    department_id int NOT NULL REFERENCES hr.departments(id),
    manager_id int REFERENCES hr.employees(id),
    employment hr.employment_type NOT NULL DEFAULT 'full_time',
    hired_on date NOT NULL,
    left_on date,
    annual_salary numeric(12,2) NOT NULL
);
COMMENT ON COLUMN hr.employees.left_on IS 'null while still employed';

CREATE TABLE hr.salary_history (
    id serial PRIMARY KEY,
    employee_id int NOT NULL REFERENCES hr.employees(id),
    effective_on date NOT NULL,
    annual_salary numeric(12,2) NOT NULL
);

CREATE TABLE hr.skills (
    id serial PRIMARY KEY,
    name text NOT NULL UNIQUE
);

CREATE TABLE hr.employee_skills (
    employee_id int NOT NULL REFERENCES hr.employees(id),
    skill_id int NOT NULL REFERENCES hr.skills(id),
    level smallint NOT NULL CHECK (level BETWEEN 1 AND 5),
    PRIMARY KEY (employee_id, skill_id)
);

CREATE TABLE hr.time_off (
    id serial PRIMARY KEY,
    employee_id int NOT NULL REFERENCES hr.employees(id),
    starts_on date NOT NULL,
    ends_on date NOT NULL,
    reason text
);

-- ---------------------------------------------------------------- sales
CREATE TYPE sales.order_status AS ENUM ('pending', 'paid', 'shipped', 'delivered', 'cancelled', 'refunded');

CREATE TABLE sales.customers (
    id bigserial PRIMARY KEY,
    name text NOT NULL,
    email text,
    country_code char(2) REFERENCES public.countries(code),
    signed_up_at timestamptz NOT NULL DEFAULT now(),
    account_manager_id int REFERENCES hr.employees(id)
);

CREATE TABLE sales.customer_addresses (
    id bigserial PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES sales.customers(id),
    line1 text NOT NULL,
    city text NOT NULL,
    postal_code text,
    country_code char(2) NOT NULL REFERENCES public.countries(code),
    is_default boolean NOT NULL DEFAULT false
);

CREATE TABLE sales.categories (
    id serial PRIMARY KEY,
    name text NOT NULL,
    parent_id int REFERENCES sales.categories(id)
);

CREATE TABLE sales.suppliers (
    id serial PRIMARY KEY,
    name text NOT NULL,
    country_code char(2) REFERENCES public.countries(code)
);

CREATE TABLE sales.products (
    id serial PRIMARY KEY,
    sku text NOT NULL UNIQUE,
    name text NOT NULL,
    category_id int REFERENCES sales.categories(id),
    supplier_id int REFERENCES sales.suppliers(id),
    unit_price numeric(10,2) NOT NULL,
    currency_code char(3) NOT NULL REFERENCES public.currencies(code),
    discontinued boolean NOT NULL DEFAULT false
);

CREATE TABLE sales.warehouses (
    id serial PRIMARY KEY,
    name text NOT NULL,
    country_code char(2) NOT NULL REFERENCES public.countries(code)
);

CREATE TABLE sales.inventory (
    warehouse_id int NOT NULL REFERENCES sales.warehouses(id),
    product_id int NOT NULL REFERENCES sales.products(id),
    quantity int NOT NULL,
    PRIMARY KEY (warehouse_id, product_id)
);

CREATE TABLE sales.orders (
    id bigserial PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES sales.customers(id),
    shipping_address_id bigint REFERENCES sales.customer_addresses(id),
    status sales.order_status NOT NULL DEFAULT 'pending',
    placed_at timestamptz NOT NULL DEFAULT now(),
    shipped_at timestamptz,
    sales_rep_id int REFERENCES hr.employees(id)
);
COMMENT ON TABLE sales.orders IS 'one row per customer order';

CREATE TABLE sales.order_items (
    order_id bigint NOT NULL REFERENCES sales.orders(id),
    line_no int NOT NULL,
    product_id int NOT NULL REFERENCES sales.products(id),
    quantity int NOT NULL,
    unit_price numeric(10,2) NOT NULL,
    discount_pct numeric(5,2) NOT NULL DEFAULT 0,
    PRIMARY KEY (order_id, line_no)
);
COMMENT ON COLUMN sales.order_items.unit_price IS 'price at time of sale';

CREATE TABLE sales.payments (
    id bigserial PRIMARY KEY,
    order_id bigint NOT NULL REFERENCES sales.orders(id),
    amount numeric(12,2) NOT NULL,
    method text NOT NULL,
    paid_at timestamptz NOT NULL
);

CREATE TABLE sales.shipments (
    id bigserial PRIMARY KEY,
    order_id bigint NOT NULL REFERENCES sales.orders(id),
    warehouse_id int NOT NULL REFERENCES sales.warehouses(id),
    carrier text NOT NULL,
    tracking_no text,
    shipped_at timestamptz,
    delivered_at timestamptz
);

CREATE TABLE sales.promotions (
    id serial PRIMARY KEY,
    code text NOT NULL UNIQUE,
    discount_pct numeric(5,2) NOT NULL,
    starts_on date NOT NULL,
    ends_on date
);

CREATE TABLE sales.order_promotions (
    order_id bigint NOT NULL REFERENCES sales.orders(id),
    promotion_id int NOT NULL REFERENCES sales.promotions(id),
    PRIMARY KEY (order_id, promotion_id)
);

CREATE TABLE sales.product_reviews (
    id bigserial PRIMARY KEY,
    product_id int NOT NULL REFERENCES sales.products(id),
    customer_id bigint NOT NULL REFERENCES sales.customers(id),
    rating smallint NOT NULL CHECK (rating BETWEEN 1 AND 5),
    body text,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE sales."ReturnRequests" (
    id bigserial PRIMARY KEY,
    "orderId" bigint NOT NULL REFERENCES sales.orders(id),
    "requestedAt" timestamptz NOT NULL,
    reason text
);
COMMENT ON TABLE sales."ReturnRequests" IS 'customer return requests (mixed-case names on purpose)';

CREATE VIEW sales.order_totals AS
SELECT o.id AS order_id, o.customer_id, sum(oi.quantity * oi.unit_price * (1 - oi.discount_pct / 100)) AS total
FROM sales.orders o JOIN sales.order_items oi ON oi.order_id = o.id
GROUP BY o.id, o.customer_id;

-- A few rows, so a grader can run a draft and see something.
INSERT INTO public.countries VALUES ('US','United States','Americas'),('DE','Germany','Europe'),('JP','Japan','Asia');
INSERT INTO public.currencies VALUES ('USD','US Dollar','$'),('EUR','Euro','€');
INSERT INTO hr.departments (name, country_code) VALUES ('Sales','US'),('Engineering','DE');
INSERT INTO hr.employees (first_name,last_name,email,department_id,employment,hired_on,annual_salary)
VALUES ('Ada','Lovelace','ada@example.com',2,'full_time','2020-01-06',150000),
       ('Grace','Hopper','grace@example.com',1,'contractor','2023-05-01',90000);
INSERT INTO sales.customers (name,email,country_code,account_manager_id) VALUES ('Acme','a@acme.test','US',2),('Bosch','b@bosch.test','DE',2);
INSERT INTO sales.categories (name) VALUES ('Tools');
INSERT INTO sales.suppliers (name,country_code) VALUES ('Makita','JP');
INSERT INTO sales.products (sku,name,category_id,supplier_id,unit_price,currency_code) VALUES ('DR-1','Drill',1,1,99.00,'USD');
INSERT INTO sales.orders (customer_id,status,placed_at) VALUES (1,'paid',now() - interval '3 days'),(2,'shipped',now() - interval '40 days');
INSERT INTO sales.order_items VALUES (1,1,1,2,99.00,0),(2,1,1,1,99.00,10);
