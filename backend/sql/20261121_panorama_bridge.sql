-- ADDITIVE migration for FastAPI panorama bridge (run after reviewing existing schema).
-- Sessions must be created by your trusted property platform after checking
-- property ownership/management permission. The capture client CANNOT INSERT.
-- If these names already exist, compare columns; IF NOT EXISTS will not alter them.
BEGIN;
CREATE SCHEMA IF NOT EXISTS fyp;
CREATE TABLE IF NOT EXISTS fyp.capture_sessions (
    session_id text PRIMARY KEY,
    owner_id uuid NOT NULL REFERENCES auth.users(id),
    property_id bigint NOT NULL,
    status text NOT NULL DEFAULT 'capturing',
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_panorama_capture_sessions_owner
    ON fyp.capture_sessions(owner_id, property_id);
CREATE TABLE IF NOT EXISTS fyp.panorama_jobs (
    id text PRIMARY KEY,
    session_id text NOT NULL REFERENCES fyp.capture_sessions(session_id),
    owner uuid NOT NULL REFERENCES auth.users(id),
    property_id bigint NOT NULL,
    status text NOT NULL DEFAULT 'queued'
        CHECK (status IN ('queued', 'processing', 'done', 'error')),
    frames jsonb NOT NULL DEFAULT '{}'::jsonb,
    panorama_path text,
    error text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_panorama_jobs_property ON fyp.panorama_jobs(property_id);
ALTER TABLE fyp.capture_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE fyp.panorama_jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON fyp.capture_sessions FROM anon, authenticated;
REVOKE ALL ON fyp.panorama_jobs FROM anon, authenticated;
GRANT USAGE ON SCHEMA fyp TO authenticated;
GRANT USAGE ON SCHEMA fyp TO service_role;
GRANT SELECT, INSERT, UPDATE ON fyp.capture_sessions TO service_role;
GRANT SELECT, INSERT, UPDATE ON fyp.panorama_jobs TO service_role;
GRANT SELECT ON fyp.capture_sessions TO authenticated;
DROP POLICY IF EXISTS capture_sessions_select_own ON fyp.capture_sessions;
CREATE POLICY capture_sessions_select_own ON fyp.capture_sessions
    FOR SELECT TO authenticated USING (owner_id = (select auth.uid()));
-- No client INSERT/UPDATE/DELETE policy; only trusted backend/service role writes.
COMMIT;
