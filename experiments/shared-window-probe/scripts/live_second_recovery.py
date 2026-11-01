"""Continue second live trial after observing the fixture was scrolled below Settings."""
from pathlib import Path
source=Path(__file__).with_name('live_second_lock.py').read_text()
exec(source.split("s=sid();print(")[0])
s=sid();before=c.status()
record('case-result',case='locked-cold-wda-input-first-attempt',outcome='failed',notes='Fixture retained scroll position; Settings was absent from current AX tree. Saved locked-cold-first-source.xml and screenshot. No evidence of a lock restriction.',before=before)
for _ in range(5):
    tree=req(s,'GET','/source')['value']
    if 'name="setting"' in tree: break
    req(s,'POST','/execute/sync',{'script':'mobile: scroll','args':[{'direction':'up'}]})
exec(source[source.index("before=c.status();req(s,'POST','/execute/sync'"):])
