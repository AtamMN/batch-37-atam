BEGIN;

-- ==========================================================
-- UTILITY TRIGGER FUNCTION FOR updated_at
-- ==========================================================
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ==========================================================
-- 1. IDENTITY, TENANCY & RBAC (Enterprise Login & Signup)
-- ==========================================================
CREATE TABLE organizations (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_name            VARCHAR(150) NOT NULL,
    company_code            VARCHAR(30)  NOT NULL UNIQUE,
    corporate_email_domain  VARCHAR(100),
    tax_registration_number VARCHAR(50),
    subscription_tier       VARCHAR(30)  NOT NULL DEFAULT 'ENTERPRISE',
    is_active               BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_org_subscription_tier
        CHECK (subscription_tier IN ('STARTER', 'GROWTH', 'ENTERPRISE'))
);

CREATE TABLE users (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id       UUID         NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
    email                 VARCHAR(255) NOT NULL UNIQUE,
    password_hash         TEXT         NOT NULL,
    full_name             VARCHAR(150) NOT NULL,
    account_status        VARCHAR(20)  NOT NULL DEFAULT 'PENDING_VERIFICATION',
    email_verified_at     TIMESTAMPTZ,
    last_login_at         TIMESTAMPTZ,
    failed_login_attempts INTEGER      NOT NULL DEFAULT 0 CHECK (failed_login_attempts >= 0),
    locked_until          TIMESTAMPTZ,
    created_at            TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at            TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_user_account_status
        CHECK (account_status IN ('PENDING_VERIFICATION', 'ACTIVE', 'SUSPENDED', 'LOCKED'))
);

CREATE TABLE user_sessions (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id            UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    refresh_token_hash TEXT        NOT NULL UNIQUE,
    ip_address         INET,
    user_agent         TEXT,
    expires_at         TIMESTAMPTZ NOT NULL,
    revoked_at         TIMESTAMPTZ,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE roles (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID         NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    code            VARCHAR(40)  NOT NULL,
    name            VARCHAR(100) NOT NULL,
    description     TEXT,
    is_system_role  BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_roles_org_code UNIQUE (organization_id, code)
);

CREATE TABLE permissions (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code        VARCHAR(80) NOT NULL UNIQUE,
    module      VARCHAR(40) NOT NULL,
    description TEXT
);

CREATE TABLE user_roles (
    user_id     UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role_id     UUID        NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    assigned_by UUID        NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    assigned_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, role_id)
);

CREATE TABLE role_permissions (
    role_id       UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    permission_id UUID NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, permission_id)
);

-- ==========================================================
-- 2. HUMAN RESOURCES (Employee List)
-- ==========================================================
CREATE TABLE departments (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id     UUID         NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    code                VARCHAR(30)  NOT NULL,
    name                VARCHAR(100) NOT NULL,
    manager_employee_id UUID,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_departments_org_code UNIQUE (organization_id, code)
);

CREATE TABLE positions (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id     UUID           NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    code                VARCHAR(30)    NOT NULL,
    title               VARCHAR(100)   NOT NULL,
    job_level           VARCHAR(30),
    default_base_salary NUMERIC(15, 2) CHECK (default_base_salary >= 0),
    created_at          TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_positions_org_code UNIQUE (organization_id, code)
);

CREATE TABLE employees (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id     UUID         NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
    user_id             UUID         UNIQUE REFERENCES users(id) ON DELETE SET NULL,
    department_id       UUID         NOT NULL REFERENCES departments(id) ON DELETE RESTRICT,
    position_id         UUID         NOT NULL REFERENCES positions(id) ON DELETE RESTRICT,
    employee_code       VARCHAR(40)  NOT NULL,
    full_name           VARCHAR(150) NOT NULL,
    work_email          VARCHAR(255) NOT NULL,
    phone_number        VARCHAR(30),
    employment_type     VARCHAR(30)  NOT NULL,
    employment_status   VARCHAR(30)  NOT NULL DEFAULT 'ACTIVE',
    hire_date           DATE         NOT NULL,
    termination_date    DATE,
    bank_name           VARCHAR(80),
    bank_account_number VARCHAR(50),
    bank_account_holder VARCHAR(150),
    tax_id_npwp         VARCHAR(40),
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_employees_org_code UNIQUE (organization_id, employee_code),
    CONSTRAINT uq_employees_org_email UNIQUE (organization_id, work_email),
    CONSTRAINT chk_employee_type
        CHECK (employment_type IN ('FULL_TIME', 'PART_TIME', 'CONTRACT', 'INTERN')),
    CONSTRAINT chk_employee_status
        CHECK (employment_status IN ('ACTIVE', 'PROBATION', 'ON_LEAVE', 'RESIGNED', 'TERMINATED')),
    CONSTRAINT chk_employee_dates
        CHECK (termination_date IS NULL OR termination_date >= hire_date)
);

-- Resolve circular foreign key between departments and employees
ALTER TABLE departments
    ADD CONSTRAINT fk_departments_manager_employee
    FOREIGN KEY (manager_employee_id) REFERENCES employees(id) ON DELETE SET NULL;

-- ==========================================================
-- 3. PAYROLL ENGINE (Payroll-Hub)
-- ==========================================================
CREATE TABLE salary_components (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID         NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    code            VARCHAR(40)  NOT NULL,
    name            VARCHAR(100) NOT NULL,
    component_type  VARCHAR(20)  NOT NULL,
    is_taxable      BOOLEAN      NOT NULL DEFAULT TRUE,
    is_recurring    BOOLEAN      NOT NULL DEFAULT TRUE,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_salary_components_org_code UNIQUE (organization_id, code),
    CONSTRAINT chk_salary_component_type
        CHECK (component_type IN ('EARNING', 'DEDUCTION', 'TAX', 'BENEFIT'))
);

CREATE TABLE employee_salary_structures (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id    UUID           NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    component_id   UUID           NOT NULL REFERENCES salary_components(id) ON DELETE RESTRICT,
    amount         NUMERIC(15, 2) NOT NULL CHECK (amount >= 0),
    effective_from DATE           NOT NULL,
    effective_to   DATE,
    is_active      BOOLEAN        NOT NULL DEFAULT TRUE,
    CONSTRAINT chk_salary_structure_dates
        CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

CREATE TABLE payroll_periods (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  UUID           NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
    period_code      VARCHAR(20)    NOT NULL,
    period_name      VARCHAR(100)   NOT NULL,
    start_date       DATE           NOT NULL,
    end_date         DATE           NOT NULL,
    payment_date     DATE           NOT NULL,
    status           VARCHAR(30)    NOT NULL DEFAULT 'DRAFT',
    total_employees  INTEGER        NOT NULL DEFAULT 0 CHECK (total_employees >= 0),
    total_gross_pay  NUMERIC(18, 2) NOT NULL DEFAULT 0 CHECK (total_gross_pay >= 0),
    total_deductions NUMERIC(18, 2) NOT NULL DEFAULT 0 CHECK (total_deductions >= 0),
    total_net_pay    NUMERIC(18, 2) NOT NULL DEFAULT 0 CHECK (total_net_pay >= 0),
    created_by       UUID           NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    verified_by      UUID           REFERENCES users(id) ON DELETE RESTRICT,
    approved_by      UUID           REFERENCES users(id) ON DELETE RESTRICT,
    created_at       TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_payroll_periods_org_code UNIQUE (organization_id, period_code),
    CONSTRAINT chk_payroll_period_dates
        CHECK (end_date >= start_date AND payment_date >= end_date),
    CONSTRAINT chk_payroll_period_status
        CHECK (status IN ('DRAFT', 'IN_REVIEW', 'VERIFIED', 'APPROVED', 'PAID', 'CANCELLED'))
);

CREATE TABLE payroll_items (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    payroll_period_id   UUID           NOT NULL REFERENCES payroll_periods(id) ON DELETE CASCADE,
    employee_id         UUID           NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
    base_salary         NUMERIC(15, 2) NOT NULL DEFAULT 0 CHECK (base_salary >= 0),
    total_allowances    NUMERIC(15, 2) NOT NULL DEFAULT 0 CHECK (total_allowances >= 0),
    total_overtime      NUMERIC(15, 2) NOT NULL DEFAULT 0 CHECK (total_overtime >= 0),
    total_deductions    NUMERIC(15, 2) NOT NULL DEFAULT 0 CHECK (total_deductions >= 0),
    tax_amount          NUMERIC(15, 2) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
    net_salary          NUMERIC(15, 2) NOT NULL DEFAULT 0 CHECK (net_salary >= 0),
    disbursement_status VARCHAR(20)    NOT NULL DEFAULT 'PENDING',
    disbursement_ref    VARCHAR(100),
    paid_at             TIMESTAMPTZ,
    notes               TEXT,
    created_at          TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_payroll_items_period_employee UNIQUE (payroll_period_id, employee_id),
    CONSTRAINT chk_disbursement_status
        CHECK (disbursement_status IN ('PENDING', 'PROCESSING', 'PAID', 'FAILED', 'ON_HOLD'))
);

CREATE TABLE payroll_item_lines (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    payroll_item_id         UUID           NOT NULL REFERENCES payroll_items(id) ON DELETE CASCADE,
    component_id            UUID           NOT NULL REFERENCES salary_components(id) ON DELETE RESTRICT,
    component_name_snapshot VARCHAR(100)   NOT NULL,
    component_type          VARCHAR(20)    NOT NULL,
    amount                  NUMERIC(15, 2) NOT NULL CHECK (amount >= 0),
    CONSTRAINT chk_item_line_component_type
        CHECK (component_type IN ('EARNING', 'DEDUCTION', 'TAX', 'BENEFIT'))
);

-- ==========================================================
-- 4. ADMIN WORKFLOW GOVERNANCE (Payroll Milestone)
-- ==========================================================
CREATE TABLE payroll_milestone_templates (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID         NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    owner_role_id   UUID         NOT NULL REFERENCES roles(id) ON DELETE RESTRICT,
    sequence_order  INTEGER      NOT NULL CHECK (sequence_order > 0),
    title           VARCHAR(120) NOT NULL,
    description     TEXT,
    due_day_offset  INTEGER      NOT NULL,
    is_mandatory    BOOLEAN      NOT NULL DEFAULT TRUE,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_milestone_templates_org_seq UNIQUE (organization_id, sequence_order)
);

CREATE TABLE payroll_milestones (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    payroll_period_id UUID         NOT NULL REFERENCES payroll_periods(id) ON DELETE CASCADE,
    template_id       UUID         REFERENCES payroll_milestone_templates(id) ON DELETE SET NULL,
    assigned_role_id  UUID         NOT NULL REFERENCES roles(id) ON DELETE RESTRICT,
    sequence_order    INTEGER      NOT NULL CHECK (sequence_order > 0),
    title             VARCHAR(120) NOT NULL,
    target_date       DATE         NOT NULL,
    status            VARCHAR(20)  NOT NULL DEFAULT 'PENDING',
    completed_by      UUID         REFERENCES users(id) ON DELETE SET NULL,
    completed_at      TIMESTAMPTZ,
    remarks           TEXT,
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_payroll_milestones_period_seq UNIQUE (payroll_period_id, sequence_order),
    CONSTRAINT chk_payroll_milestone_status
        CHECK (status IN ('PENDING', 'IN_PROGRESS', 'COMPLETED', 'BLOCKED', 'SKIPPED'))
);

-- ==========================================================
-- INDEXES FOR FOREIGN KEYS & FREQUENT QUERIES
-- ==========================================================
CREATE INDEX idx_users_org_id ON users(organization_id);
CREATE INDEX idx_user_sessions_user_id ON user_sessions(user_id);
CREATE INDEX idx_roles_org_id ON roles(organization_id);
CREATE INDEX idx_user_roles_role_id ON user_roles(role_id);
CREATE INDEX idx_role_permissions_perm_id ON role_permissions(permission_id);

CREATE INDEX idx_departments_org_id ON departments(organization_id);
CREATE INDEX idx_positions_org_id ON positions(organization_id);
CREATE INDEX idx_employees_org_status ON employees(organization_id, employment_status);
CREATE INDEX idx_employees_department_id ON employees(department_id);
CREATE INDEX idx_employees_position_id ON employees(position_id);

CREATE INDEX idx_emp_salary_structures_emp_active ON employee_salary_structures(employee_id, is_active);
CREATE INDEX idx_payroll_periods_org_status ON payroll_periods(organization_id, status);
CREATE INDEX idx_payroll_items_period_id ON payroll_items(payroll_period_id);
CREATE INDEX idx_payroll_items_employee_id ON payroll_items(employee_id);
CREATE INDEX idx_payroll_item_lines_item_id ON payroll_item_lines(payroll_item_id);

CREATE INDEX idx_milestone_templates_org_id ON payroll_milestone_templates(organization_id);
CREATE INDEX idx_payroll_milestones_period_status ON payroll_milestones(payroll_period_id, status);
CREATE INDEX idx_payroll_milestones_assigned_role ON payroll_milestones(assigned_role_id);

-- ==========================================================
-- AUTOMATIC updated_at TRIGGERS
-- ==========================================================
CREATE TRIGGER trg_organizations_updated_at
    BEFORE UPDATE ON organizations
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_employees_updated_at
    BEFORE UPDATE ON employees
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_payroll_periods_updated_at
    BEFORE UPDATE ON payroll_periods
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_payroll_items_updated_at
    BEFORE UPDATE ON payroll_items
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_payroll_milestones_updated_at
    BEFORE UPDATE ON payroll_milestones
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMIT;