-- Check 04: Authentication posture and pg_hba.conf rule audit.
-- Inspects server password_encryption alongside pg_catalog.pg_hba_file_rules
-- to highlight high-risk auth methods (trust, plaintext password, wide md5).
SELECT
    r.line_number,
    r.type,
    r.database,
    r.user_name,
    r.address,
    r.netmask,
    r.auth_method,
    current_setting('password_encryption') AS password_encryption,
    r.error,
    CASE
        WHEN r.error IS NOT NULL THEN 'invalid_hba_rule'
        WHEN r.auth_method = 'trust' THEN 'high_risk_trust_auth'
        WHEN r.auth_method = 'password' THEN 'high_risk_plaintext_password'
        WHEN r.auth_method = 'md5' AND (
            r.address IN ('0.0.0.0/0', '::/0', 'all', 'samehost', 'samenet')
            OR (r.address = '0.0.0.0' AND r.netmask = '0.0.0.0')
            OR (r.address = '::' AND r.netmask = '::')
        ) THEN 'high_risk_md5_wide_cidr'
        WHEN r.auth_method = 'md5' THEN 'warn_legacy_md5'
        WHEN r.auth_method IN ('scram-sha-256', 'peer', 'cert') THEN 'ok'
        ELSE 'review_' || COALESCE(r.auth_method, 'unknown')
    END AS risk_note
FROM pg_catalog.pg_hba_file_rules AS r
ORDER BY r.line_number ASC;
