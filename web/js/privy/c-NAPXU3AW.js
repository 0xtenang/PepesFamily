var r=new Set(["https:","mailto:"]);function e(t){if(!t)return null;try{if(r.has(new URL(t).protocol))return t}catch{}return null}export{e as a};
