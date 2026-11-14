import random, sys
random.seed(7)
DEMON=["1000001","1100011","0111110","0101010","0111110","0011100","0010100"]
W,H=880,330; LOOP=16.0
BG='#0e0f11'; INK='#e2e4e8'; DIM='#8a8f97'; FAINT='#2a2d32'; LINE='#1d1f23'
C={'need':'#e8a33d','turn':'#a395f2','work':'#8a8f97','safe':'#74c48d'}
G=[('need','NEEDS YOU','●'),('turn','YOUR TURN','◐'),('work','WORKING','○'),('safe','SAFE TO CLOSE','✓')]
GL=dict((k,gl) for k,_,gl in G)
P=17; D=P*7; DX=360; DY=(H-D)//2
FONT="ui-monospace,SFMono-Regular,'SF Mono',Menlo,Consolas,monospace"
sess=[('stripe-webhooks','need'),('onboarding-copy','turn'),('flaky-e2e','work'),('release-v0.1.7','safe'),
      ('web-auth','need'),('fix-logo-orientation','turn'),('ios-push','work'),('landing-page','safe'),('rate-limiter','work')]
LX=560; lh=19
slots={}; y=44
for k,label,gl in G:
    slots[k]={'hy':y,'n':0}; y+=lh*(1+(3 if k=='work' else 2))+10
t0=3.4; step=1.15; travel=3.2
pct=lambda t: max(0,min(100,t/LOOP*100))
css=[]; toks=[]; ents=[]
for i,(n,g) in enumerate(sess):
    ta=t0+i*step; s=slots[g]; ty=s['hy']+lh*(1+s['n']); s['n']+=1
    y0=random.randint(40,H-40); yy=DY+D/2+random.randint(-34,34); ts=ta-travel
    xe=DX-8-len(n)*7.5
    css.append(f"@keyframes t{i}{{0%,{pct(ts):.2f}%{{transform:translate(-30px,{y0}px);opacity:0}}{pct(ts+.6):.2f}%{{opacity:.85}}{pct(ta-.25):.2f}%{{opacity:.85}}{pct(ta):.2f}%,100%{{transform:translate({xe:.0f}px,{yy}px);opacity:0}}}}")
    toks.append(f'<text class="tok" style="animation-name:t{i}">{n}</text>')
    tr=ta+.45
    css.append(f"@keyframes e{i}{{0%,{pct(tr):.2f}%{{opacity:0;transform:translateX(-12px)}}{pct(tr+.35):.2f}%,94%{{opacity:1;transform:none}}98%,100%{{opacity:0}}}}")
    ents.append(f'<g class="ent" style="animation-name:e{i}"><text x="{LX}" y="{ty}" fill="{C[g]}">{GL[g]}</text><text x="{LX+18}" y="{ty}" fill="{INK}">{n}</text></g>')
# demon reacts: eyes glance left on intake (blink + shift is too busy; keep blink)
css.append("@keyframes blink{0%,46%,49%,100%{opacity:1}47%,48%{opacity:0}}")
dots=''.join(f'<text x="{x}" y="{yy}" fill="{LINE}">·</text>' for yy in range(42,H-10,20) for x in range(18+(yy//20%2)*14,DX-34,28))
demon=''.join(f'<rect x="{DX+c*P+1.5}" y="{DY+r*P+1.5}" width="{P-3}" height="{P-3}" fill="{INK if v=="1" else FAINT}"/>' for r,row in enumerate(DEMON) for c,v in enumerate(row))
eyes=''.join(f'<rect x="{DX+c*P+1.5}" y="{DY+3*P+1.5}" width="{P-3}" height="{P-3}" fill="#e8a33d"/>' for c in (2,4))
wall=''.join(f'<text x="{DX+D/2-3.5}" y="{yy}" fill="{FAINT}">┊</text>' for yy in range(18,H,18) if not (DY-14<yy<DY+D+18))
heads=''.join(f'<text x="{LX}" y="{slots[k]["hy"]}" fill="{C[k]}" font-size="11.5" letter-spacing="1">{label}</text><line x1="{LX+len(label)*7.9+14}" x2="{W-28}" y1="{slots[k]["hy"]-4}" y2="{slots[k]["hy"]-4}" stroke="{LINE}"/>' for k,label,gl in G)
svg=f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-label="Maxwell: session names drift in, a pixel demon sorts them into Needs you, Your turn, Working and Safe to close.">
<style>
text{{font-family:{FONT};font-size:12.5px}}
.tok{{fill:{DIM};opacity:0;animation-duration:{LOOP}s;animation-iteration-count:infinite;animation-timing-function:cubic-bezier(.45,.05,.55,.95)}}
.ent{{opacity:0;animation-duration:{LOOP}s;animation-iteration-count:infinite;animation-timing-function:ease-out}}
.eyes{{animation:blink 4.2s infinite steps(1)}}
{chr(10).join(css)}
@media (prefers-reduced-motion:reduce){{.tok{{animation:none}}.ent{{animation:none;opacity:1}}.eyes{{animation:none}}}}
</style>
<rect width="{W}" height="{H}" rx="14" fill="{BG}"/>
{dots}
<text x="22" y="26" fill="#3d4047" font-size="11">unsorted</text>
{wall}
{''.join(toks)}
{demon}<g class="eyes">{eyes}</g>
{heads}
{''.join(ents)}
<text x="{DX+D/2}" y="{H-20}" fill="{DIM}" font-size="11" text-anchor="middle" letter-spacing="2">MAXWELL</text>
</svg>'''
open(sys.argv[1],'w').write(svg)
