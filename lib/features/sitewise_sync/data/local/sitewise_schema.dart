/// The SQLite schema for the SiteWise capture app's local-first store.
///
/// ## Why SQLite here
///
/// The 38-target flow already persisted its evidence as JSON files beside the
/// JPEGs, and that is still what the stitcher reads. What JSON could not answer
/// is the question this change introduces: *which panoramas are waiting to go to
/// Supabase, which of them failed, and how many times?* A retry queue needs
/// transactions, indexes and uniqueness — so the metadata moved to SQLite while
/// the pixels stayed where they were, in application file storage.
///
/// ## What is deliberately **not** stored
///
/// No image bytes. Not the 38 JPEGs, not the panorama. A session's 38 frames are
/// tens of megabytes; copying them into BLOBs would double the app's disk use
/// and make every metadata query read megabytes. The rows hold absolute paths
/// into the same directories the capture code already writes.
///
/// ## Versioning
///
/// [kSitewiseSchemaVersion] drives `onCreate`/`onUpgrade`, and every applied
/// version is also recorded in `schema_migrations` so a support bundle can say
/// what shape the database is in without opening it. Migrations are additive:
/// no statement in this file drops a table, and no migration deletes capture
/// rows.
library;

/// The schema version this build understands.
///
/// Bump it and add a step to [sitewiseMigrationStatements] in the same commit.
const int kSitewiseSchemaVersion = 1;

/// The statements that create a fresh database at [kSitewiseSchemaVersion].
///
/// Order matters: `captured_frames` and `panorama_sync` reference
/// `capture_sessions`, and SQLite only enforces a foreign key on a table that
/// already exists.
const List<String> kSitewiseCreateStatements = <String>[
  '''
  CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY NOT NULL,
    description TEXT NOT NULL,
    applied_at INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS capture_sessions (
    session_id TEXT PRIMARY KEY NOT NULL,
    user_id TEXT,
    property_id INTEGER,
    required_target_count INTEGER NOT NULL DEFAULT 38
      CHECK (required_target_count > 0),
    status TEXT NOT NULL DEFAULT 'draft'
      CHECK (status IN ('draft', 'capturing', 'complete', 'panorama_ready', 'panorama_failed', 'abandoned')),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    local_panorama_path TEXT,
    panorama_status TEXT NOT NULL DEFAULT 'pending'
      CHECK (panorama_status IN ('pending', 'generating', 'ready', 'failed')),
    last_error TEXT
  )
  ''',
  // The resume path asks "newest unfinished session for this account", and the
  // sync path asks "every session with a finished panorama". Both are indexes.
  '''
  CREATE INDEX IF NOT EXISTS ix_capture_sessions_user_updated
    ON capture_sessions (user_id, updated_at DESC)
  ''',
  '''
  CREATE INDEX IF NOT EXISTS ix_capture_sessions_status
    ON capture_sessions (status)
  ''',
  '''
  CREATE INDEX IF NOT EXISTS ix_capture_sessions_property
    ON capture_sessions (property_id)
  ''',
  '''
  CREATE TABLE IF NOT EXISTS captured_frames (
    session_id TEXT NOT NULL
      REFERENCES capture_sessions (session_id) ON DELETE CASCADE,
    target_id INTEGER NOT NULL CHECK (target_id BETWEEN 1 AND 38),
    image_path TEXT NOT NULL,
    captured_at INTEGER NOT NULL,
    target_yaw_deg REAL NOT NULL,
    target_pitch_deg REAL NOT NULL,
    camera_qx REAL NOT NULL,
    camera_qy REAL NOT NULL,
    camera_qz REAL NOT NULL,
    camera_qw REAL NOT NULL,
    image_width INTEGER NOT NULL,
    image_height INTEGER NOT NULL,
    source_width INTEGER NOT NULL DEFAULT 0,
    source_height INTEGER NOT NULL DEFAULT 0,
    crop_offset_x INTEGER NOT NULL DEFAULT 0,
    crop_offset_y INTEGER NOT NULL DEFAULT 0,
    alignment_error_deg REAL NOT NULL DEFAULT 0,
    tolerance_deg REAL NOT NULL DEFAULT 0,
    capture_status TEXT NOT NULL DEFAULT 'captured',
    PRIMARY KEY (session_id, target_id)
  )
  ''',
  // One target has exactly one frame per session: the composite primary key is
  // the duplicate guard, and a retake replaces the row rather than appending a
  // second one for the same photograph.
  '''
  CREATE INDEX IF NOT EXISTS ix_captured_frames_session
    ON captured_frames (session_id)
  ''',
  '''
  CREATE TABLE IF NOT EXISTS panorama_sync (
    session_id TEXT PRIMARY KEY NOT NULL
      REFERENCES capture_sessions (session_id) ON DELETE CASCADE,
    local_panorama_path TEXT,
    job_id TEXT,
    remote_object_path TEXT,
    property_id INTEGER,
    status TEXT NOT NULL DEFAULT 'pending'
      CHECK (status IN ('pending', 'uploading', 'uploaded', 'failed', 'blocked')),
    retry_count INTEGER NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    last_error TEXT,
    last_attempt_at INTEGER,
    last_success_at INTEGER,
    claimed_at INTEGER,
    updated_at INTEGER NOT NULL
  )
  ''',
  // A cloud job belongs to one session. Without this, a retry that raced itself
  // could insert a second row for the same `pano_jobs.id` and the queue would
  // upload the same panorama twice.
  '''
  CREATE UNIQUE INDEX IF NOT EXISTS ux_panorama_sync_job
    ON panorama_sync (job_id) WHERE job_id IS NOT NULL
  ''',
  // The upload queue's own query: "everything still to do, oldest first".
  '''
  CREATE INDEX IF NOT EXISTS ix_panorama_sync_status_updated
    ON panorama_sync (status, updated_at)
  ''',
];

/// Additive migration steps, keyed by the version they produce.
///
/// Version 1 is the initial schema, so there is nothing to migrate *to* yet.
/// The map exists (and is read by `onUpgrade`) so the first real migration is a
/// data change rather than a structural one.
const Map<int, List<String>> sitewiseMigrationStatements = <int, List<String>>{};

/// Recorded descriptions for `schema_migrations`, so the table is readable.
const Map<int, String> kSitewiseMigrationDescriptions = <int, String>{
  1: 'Initial local-first capture session, frame and panorama sync schema',
};
