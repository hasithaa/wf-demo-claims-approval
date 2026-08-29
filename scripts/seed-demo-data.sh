#!/usr/bin/env bash
# Populates a lived-in demo: historical claims in every terminal state for alice and
# bob (portal-filed and AI-filed alike), plus the bell notifications that told the
# story. Everything here is plain durable-record data — settled claims need no live
# workflow behind them.
#
# Deliberately NOT seeded: pending claims and open conversations. Anything a manager
# or accountant could act on must ride a real workflow — create those through the
# portal (or scripts/walkthrough.sh) so the decisions actually work.
#
#   scripts/seed-demo-data.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

echo "-- seeding historical claims"
docker compose exec -T appdb psql -q -U app -d claims_db <<'SQL'
INSERT INTO claims (claim_id, workflow_id, submitted_by, amount, status, bill_url, note, filed_via, updated_at)
VALUES
  ('CLM-SEED-0001', 'seed', 'alice', 640.00,  'PAID',     NULL,
   'PAY-CLM-SEED-0001', 'portal', now() - interval '9 days'),
  ('CLM-SEED-0002', 'seed', 'alice', 2150.00, 'PAID',
   'http://localhost:9081/bills/seed-0002/file', 'PAY-CLM-SEED-0002', 'portal', now() - interval '6 days'),
  ('CLM-SEED-0003', 'seed', 'alice', 380.00,  'REJECTED', NULL,
   'Duplicate of an already-settled claim', 'portal', now() - interval '4 days'),
  ('CLM-SEED-0004', 'seed', 'bob',   890.00,  'PAID',     NULL,
   'PAY-CLM-SEED-0004', 'agent',  now() - interval '3 days'),
  ('CLM-SEED-0005', 'seed', 'bob',   4700.00, 'PAID',
   'http://localhost:9081/bills/seed-0005/file', 'PAY-CLM-SEED-0005', 'agent', now() - interval '1 day')
ON CONFLICT (claim_id) DO NOTHING;
SQL

echo "-- seeding the bells"
docker compose exec -T appdb psql -q -U app -d notifications_db <<'SQL'
INSERT INTO notifications (username, title, body, link, is_read, created_at)
VALUES
  ('alice', 'Claim CLM-SEED-0001 paid',     'Reference PAY-CLM-SEED-0001.',                    NULL, TRUE,  now() - interval '9 days'),
  ('alice', 'Claim CLM-SEED-0002 paid',     'Reference PAY-CLM-SEED-0002.',                    NULL, TRUE,  now() - interval '6 days'),
  ('alice', 'Claim CLM-SEED-0003 rejected', 'Duplicate of an already-settled claim.',          NULL, FALSE, now() - interval '4 days'),
  ('bob',   'Claim CLM-SEED-0004 paid',     'Filed by the Smart Claim agent; reference PAY-CLM-SEED-0004.', NULL, TRUE, now() - interval '3 days'),
  ('bob',   'Claim CLM-SEED-0005 paid',     'Filed by the Smart Claim agent; reference PAY-CLM-SEED-0005.', NULL, FALSE, now() - interval '1 day'),
  ('jane',  'Nothing pending',              'The review queue is clear.',                      NULL, FALSE, now() - interval '1 day'),
  ('john',  'Nothing pending',              'No payments await release.',                      NULL, FALSE, now() - interval '1 day')
ON CONFLICT DO NOTHING;
SQL

echo "done. alice has 3 historical claims, bob has 2 AI-filed ones (badge included)."
echo "For live pending work, file a claim in the portal or run scripts/walkthrough.sh."
