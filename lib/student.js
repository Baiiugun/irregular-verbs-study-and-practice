import {createCloudClient,normalizeName,localDate,PresenceClock,escapeHTML} from './cloud.js';
const api=createCloudClient(),$=id=>document.getElementById(id),labels={junior:'初中',senior:'高中'};
let visit=null,clock=null,timer=null,assignments=[],refreshTicks=0,joining=false;
const status=(text,error=false)=>{$('cloud-status').textContent=text;$('cloud-status').classList.toggle('error',error);};
const foreground=()=>document.visibilityState==='visible'&&document.hasFocus();
function showDownloads(){const level=window.IVLearning.getLevel(),label=labels[level];$('download-heading').textContent=label+' PDF';for(const [id,kind,text]of[['download-study','study','学习版'],['download-spelling','spelling','拼写版']]){const a=$(id);a.href=`downloads/${level}-${kind}.pdf`;a.download=`${label}-${text}.pdf`;a.textContent=`↓ 下载${text} PDF`;}}
function showAssignments(){const today=localDate();$('student-assignments').innerHTML=assignments.map(a=>`<button type="button" class="assignment-button" data-assignment="${escapeHTML(a.id)}"><strong>${a.date===today?'今天':escapeHTML(a.date)} · ${labels[a.level]} ${String(a.start).padStart(3,'0')}—${String(a.end).padStart(3,'0')}</strong><small>按老师布置开始学习${a.note?' · '+escapeHTML(a.note):''}</small></button>`).join('');}
async function refreshAssignments(){if(!visit)return;try{assignments=await api.rpc('iv_get_assignments',{p_visit_id:visit.id,p_secret:visit.secret,p_day:localDate()});showAssignments();}catch{/* 下一次心跳再试 */}}
async function ping(finished=false){
 if(!visit||!clock)return;
 const current=visit;clock.setVisible(!finished&&foreground());const sample=clock.snapshot();
 try{await api.rpc('iv_ping_visit',{p_visit_id:current.id,p_secret:current.secret,...sample,p_finished:finished},{keepalive:finished||!sample.p_visible});if(visit===current)status(`当前：${current.name} · 学习时段已连接。页面在前台时累计时长，切到后台会暂停。`);}
 catch(error){if(visit!==current)return;if(error.status===403){clearInterval(timer);timer=null;visit=null;clock=null;localStorage.removeItem('iv_student_name');$('student-name').readOnly=false;$('student-enter').hidden=false;$('student-change').hidden=true;status('这个学生记录已被移除，请重新填写老师指定的缩写。',true);}else status('学习页面可继续使用，访问记录暂未连上，联网后会自动重试。',true);}
}
async function join(name){
 if(joining)return;name=normalizeName(name);joining=true;$('student-enter').disabled=true;
 try{
  if(visit)await ping(true);clearInterval(timer);visit=null;
  const id=crypto.randomUUID(),secret=crypto.randomUUID(),nextClock=new PresenceClock();nextClock.setVisible(foreground());
  const result=await api.rpc('iv_begin_visit',{p_name:name,p_visit_id:id,p_secret:secret,p_day:localDate()});
  window.IVLearning.setStudent(result.student_id);visit={id,secret,name:result.name};clock=nextClock;assignments=result.assignments||[];localStorage.setItem('iv_student_name',result.name);
  $('student-name').value=result.name;$('student-name').readOnly=true;$('student-enter').hidden=true;$('student-change').hidden=false;
  showAssignments();showDownloads();const today=assignments.find(a=>a.date===localDate()&&a.level===window.IVLearning.getLevel())||assignments.find(a=>a.date===localDate());
  if(today){window.IVLearning.applyAssignment(today);showDownloads();}
  status(`当前：${result.name} · 已记录进入时间；无需打字或交卷，页面在前台时就会累计时长。`);
  timer=setInterval(()=>{if(foreground())void ping();if(++refreshTicks%3===0&&document.visibilityState==='visible')void refreshAssignments();},20000);
  void ping();
 }catch(error){status(error.status===404?'云端记录还未启用，学习页面和 PDF 下载可以先使用。':'连接未成功，请检查网络后再次点击“进入学习”。',true);}
 finally{joining=false;$('student-enter').disabled=false;}
}
$('student-entry').addEventListener('submit',event=>{event.preventDefault();try{void join(normalizeName($('student-name').value));}catch(error){status(error.message,true);}});
$('student-change').addEventListener('click',async()=>{await ping(true);clearInterval(timer);timer=null;visit=null;clock=null;assignments=[];localStorage.removeItem('iv_student_name');showAssignments();$('student-name').readOnly=false;$('student-enter').hidden=false;$('student-change').hidden=true;$('student-name').value='';$('student-name').focus();status('请填写新的姓名缩写，再点击“进入学习”。');});
$('student-assignments').addEventListener('click',event=>{const button=event.target.closest('[data-assignment]');if(!button)return;const assignment=assignments.find(a=>a.id===button.dataset.assignment);if(assignment){window.IVLearning.applyAssignment(assignment);showDownloads();}});
document.addEventListener('click',event=>{if(event.target.closest('[data-level]'))queueMicrotask(showDownloads);});
for(const event of ['focus','blur'])window.addEventListener(event,()=>{if(clock){clock.setVisible(foreground());void ping();}});
document.addEventListener('visibilitychange',()=>{if(clock){clock.setVisible(foreground());void ping();}});
window.addEventListener('pagehide',()=>{void ping(true);});
window.addEventListener('pageshow',()=>{if(clock){clock.setVisible(foreground());void ping();}});
window.addEventListener('online',()=>{if(visit)void ping();});
showDownloads();
try{const linked=new URLSearchParams(location.hash.slice(1)).get('student'),saved=localStorage.getItem('iv_student_name'),name=linked||saved;if(name){$('student-name').value=normalizeName(name);void join(name);}}catch{/* 无有效名字时等待填写 */}
