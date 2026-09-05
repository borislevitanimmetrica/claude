-- dma_cidrs.sql
-- Emit ONLY the matched IPv4 CIDR ranges for one DMA, one per line, no headers.
-- This is the input to the address enumerator.
--
-- Usage:
--   psql "$DATABASE_URL" -v DMA="Indianapolis, IN DMA" -At -f dma_cidrs.sql > dma_cidrs.txt
--
-- -A is unaligned output and -t suppresses headers, so the result is a clean
-- list suitable for piping.
--
-- Contains NO backslashes so it survives copy/paste.

SELECT DISTINCT s.network::text
FROM ip2city_dbiplite_tbl s
JOIN dma2city_tbl d
  ON s.city = d.city AND s.state = d.state
WHERE d.dma = :'DMA'
  AND family(s.network) = 4
ORDER BY 1;
