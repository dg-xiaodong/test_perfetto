-- Aggregate shape of the recorded flow graph: which stage pairs are connected.
SELECT a.name AS from_slice, b.name AS to_slice, COUNT(*) AS edges
FROM flow f JOIN slice a ON a.id=f.slice_out JOIN slice b ON b.id=f.slice_in
GROUP BY a.name, b.name ORDER BY edges DESC
