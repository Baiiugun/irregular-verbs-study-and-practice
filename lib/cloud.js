import { SUPABASE_URL, ANON_KEY } from './config.js';
export function normalizeName(value){const name=String(value||'').normalize('NFKC').trim().toUpperCase();if(!/^[A-Z][A-Z0-9_-]{0,23}$/.test(name))throw new Error('请填写姓名缩写，例如 LXM；可用字母、数字、横线，最多 24 位。');return name;}
export function localDate(date=new Date()){return [date.getFullYear(),String(date.getMonth()+1).padStart(2,'0'),String(date.getDate()).padStart(2,'0')].join('-');}
export function formatDuration(ms){const seconds=Math.max(0,Math.floor(Number(ms||0)/1000));return seconds>=3600?`${Math.floor(seconds/3600)}小时${Math.floor(seconds%3600/60)}分`:seconds>=60?`${Math.floor(seconds/60)}分${seconds%60}秒`:`${seconds}秒`;}
export function formatTime(value){return value?new Intl.DateTimeFormat('zh-CN',{month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hour12:false}).format(new Date(value)):'—';}
export function escapeHTML(value){return String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
export class PresenceClock{
 constructor(now=()=>performance.now()){this.now=now;this.last=now();this.visible=false;this.total=0;this.seq=0;}
 advance(){const current=this.now();if(this.visible)this.total+=Math.max(0,current-this.last);this.last=current;}
 setVisible(visible){this.advance();this.visible=Boolean(visible);}
 snapshot(){this.advance();return {p_seq:++this.seq,p_total_ms:Math.floor(this.total),p_visible:this.visible};}
}
export function createCloudClient(fetcher=globalThis.fetch){
 async function request(path,{method='POST',body,token,keepalive=false}={}){
  const response=await fetcher(SUPABASE_URL+path,{method,signal:typeof AbortSignal!=='undefined'?AbortSignal.timeout(15000):undefined,headers:{apikey:ANON_KEY,Authorization:'Bearer '+(token||ANON_KEY),'Content-Type':'application/json'},body:body===undefined?undefined:JSON.stringify(body),keepalive});
  const text=await response.text();let data;try{data=text?JSON.parse(text):null;}catch{data=null;}
  if(!response.ok){const error=new Error(data?.message||data?.error_description||data?.msg||`连接失败（${response.status}）`);error.status=response.status;error.code=data?.code;throw error;}
  return data;
 }
 return {rpc:(name,body,options={})=>request('/rest/v1/rpc/'+name,{body,...options}),login:(email,password)=>request('/auth/v1/token?grant_type=password',{body:{email,password}}),refresh:refresh_token=>request('/auth/v1/token?grant_type=refresh_token',{body:{refresh_token}}),logout:token=>request('/auth/v1/logout',{body:{},token})};
}
