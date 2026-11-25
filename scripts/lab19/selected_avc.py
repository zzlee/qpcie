"""Choose among the completed, verified long AVC cells for one rate."""
import csv, sys
from pathlib import Path
rows = [r for r in csv.DictReader(Path(sys.argv[1]).open(), delimiter='\t')
        if r['rate'] == sys.argv[2] and r['run'].endswith('-long') and r['clean']=='True'
        and r['L2']=='1' and float(r['overlap_s'])>=600]
assert {r['P'] for r in rows} == {'8', '16'}, 'both corroborating long runs required'
def score(r):
    missing, observed = int(r['overlap_miss']), int(r['overlapN'])
    return (missing/(missing+observed), int(r['whole_miss'])/int(r['whole_pictures']), int(r['P']))
print(min(rows,key=score)['P'])
