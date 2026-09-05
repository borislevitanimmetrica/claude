-- dma_cidrs.sql
-- Emit ONLY the matched IPv4 CIDR ranges for one DMA, one per line, no headers.
-- This is the input to the expand_cidrs address enumerator.
--
-- Usage:
--   psql "$DATABASE_URL" -At -f dma_cidrs.sql > dma_cidrs.txt
--
-- -A is unaligned and -t suppresses headers, giving a clean pipeable list.
--
-- This file is deliberately a SINGLE statement with the DMA name inlined. An
-- earlier version used a temp table for the parameter, but CREATE TEMP TABLE
-- emits a "SELECT 1" command tag that corrupted the piped output.
--
-- To change the DMA, edit the quoted name below.
--
-- Contains NO backslashes so it survives copy/paste.

SELECT DISTINCT s.network::text
FROM ip2city_dbiplite_tbl s
JOIN dma2city_tbl d
  ON s.city = d.city AND s.state = d.state
WHERE d.dma = 'Indianapolis, IN DMA'
  AND family(s.network) = 4
ORDER BY 1;
