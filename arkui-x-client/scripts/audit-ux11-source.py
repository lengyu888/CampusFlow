from pathlib import Path
import hashlib,json,re
repo=Path(__file__).resolve().parents[2];base=repo/'arkui-x-client/entry/src/main/ets'
files=['theme/AppTheme.ets','components/AppIcon.ets','components/AppIllustration.ets','components/TaskStatusPanel.ets','pages/Index.ets','pages/HomePage.ets','pages/AgentPage.ets','pages/PlanCenterPage.ets','pages/OnboardingPage.ets','pages/TimetablePage.ets','pages/FocusPage.ets','pages/ReviewPage.ets']
texts={n:(base/n).read_text() for n in files}
colors=dict(re.findall(r"static readonly (\w+): string = '(#[0-9A-Fa-f]{6})'",texts['theme/AppTheme.ets']))
def luminance(h):
 vals=[int(h[i:i+2],16)/255 for i in (1,3,5)];v=[x/12.92 if x<=.04045 else ((x+.055)/1.055)**2.4 for x in vals]
 return sum(x*y for x,y in zip(v,[.2126,.7152,.0722]))
pairs=[('ink','canvas'),('ink','surface'),('secondary','canvas'),('secondary','surface'),('accent','surface'),('onAccent','accent'),('warning','warningSoft'),('danger','dangerSoft'),('success','successSoft'),('secondary','accentSoft')]
ratios=[{'foreground':a,'background':b,'ratio':round((max(luminance(colors[a]),luminance(colors[b]))+.05)/(min(luminance(colors[a]),luminance(colors[b]))+.05),2)} for a,b in pairs]
assert all(row['ratio']>=4.5 for row in ratios)
checks=[('decorative_icons_and_illustrations',all(".accessibilityLevel('no')" in texts[n] for n in ['components/AppIcon.ets','components/AppIllustration.ets'])),('reduced_motion_path',"'reduceMotion'" in texts['theme/AppTheme.ets'] and '? 0 : duration' in texts['theme/AppTheme.ets']),('calendar_touch_width_and_horizontal_scroll','Math.max(336,' in texts['pages/PlanCenterPage.ets'] and "columnsTemplate('repeat(7, 1fr)')" in texts['pages/PlanCenterPage.ets']),('input_keyboard_resize','KeyboardAvoidMode.RESIZE' in texts['pages/Index.ets']),('voice_explicit_label_and_editable_input','识别后可编辑，不自动发送' in texts['pages/AgentPage.ets']),('status_labels_include_text','accessibilityText(`${this.label(item)}，${this.phaseLabel(item)}`)' in texts['components/TaskStatusPanel.ets']),('core_task_controls_minimum_size',all('minHeight: 48' in texts[n] for n in ['pages/HomePage.ets','pages/AgentPage.ets','pages/PlanCenterPage.ets','pages/FocusPage.ets','pages/ReviewPage.ets']))]
assert all(ok for _,ok in checks),checks
assets=[]
for p in sorted((repo/'arkui-x-client/entry/src/main/resources/base/media').glob('xj_*.png')):
 assets.append({'path':str(p.relative_to(repo)),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
result={'kind':'source audit and arithmetic measurements, not native accessibility certification','source_sha256':{n:hashlib.sha256((base/n).read_bytes()).hexdigest() for n in files},'text_color_pairs':ratios,'source_checks':[{'name':n,'passed':ok} for n,ok in checks],'original_art':assets,'original_art_bytes':sum(x['bytes'] for x in assets),'native_pending':['Actual system text scaling and layout at large font sizes','Platform screen reader labels, focus order and announcements','Physical touch targets, keyboard, safe areas and device back gesture','Real startup/frame/memory measurements'],'observations':['Source contains textual task statuses and confirmations; color is not the only state cue.','Month calendar keeps seven 48 vp columns by horizontal scrolling on narrow widths; optional month view remains separate from daily list.','Decorative artwork has a source-level fallback and no accessibility name; functional text remains in normal controls.','Prototype timings and sizes are reported separately and cannot establish native performance.']}
(repo/'docs/evidence/ux-11-accessibility-audit.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'text_pairs':len(ratios),'minimum_ratio':min(x['ratio'] for x in ratios),'source_checks':len(checks),'art_files':len(assets),'art_bytes':result['original_art_bytes']},ensure_ascii=False))
