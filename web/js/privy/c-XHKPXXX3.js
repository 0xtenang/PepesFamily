import{a as j}from"./c-DQDETRUI.js";import{a as O}from"./c-MEQB3KCL.js";import{a as g}from"./c-QXFYOOCT.js";import{a as I}from"./c-HHVY6T6T.js";import{a as T}from"./c-4SLBV5H6.js";import"./c-I2CAKQUV.js";import"./c-PVBQCY52.js";import"./c-6SGKDJ7B.js";import"./c-RDB4ZZZP.js";import{b as C}from"./c-VKHXICOU.js";import{b as o,f as F}from"./c-BWLHDX22.js";import{a as N}from"./c-4Q4QKSPE.js";import"./c-ZM4KEEHC.js";import"./c-7QDMPFCK.js";import"./c-RGDXZPSH.js";import"./c-FKNR4ZMH.js";import{Ca as S,Sa as w,wb as b}from"./c-MZSQCKNV.js";import"./c-BMXE255U.js";import"./c-T25CEWFK.js";import{a as M,b as E}from"./c-Y4USFN7N.js";import"./c-S45QUDWV.js";import"./c-ZOH7T4WV.js";import"./c-O76DOGOV.js";import"./c-4ERX45K7.js";import{f as y}from"./c-K7HT7LU7.js";var e=y(E(),1),r=y(M(),1),d=y(N(),1);var q="#8a63d2",P=({appName:m,loading:f,success:u,errorMessage:a,connectUri:t,onBack:s,onClose:n,onOpenFarcaster:i})=>(0,e.jsx)(T,d.isMobile||f?d.isIOS?{title:a?a.message:"Add a signer to Farcaster",subtitle:a?a.detail:`This will allow ${m} to add casts, likes, follows, and more on your behalf.`,icon:g,iconVariant:"loading",iconLoadingStatus:{success:u,fail:!!a},primaryCta:t&&i?{label:"Open Farcaster app",onClick:i}:void 0,onBack:s,onClose:n,watermark:!0}:{title:a?a.message:"Requesting signer from Farcaster",subtitle:a?a.detail:"This should only take a moment",icon:g,iconVariant:"loading",iconLoadingStatus:{success:u,fail:!!a},onBack:s,onClose:n,watermark:!0,children:t&&d.isMobile&&(0,e.jsx)(R,{children:(0,e.jsx)(O,{text:"Take me to Farcaster",url:t,color:q})})}:{title:"Add a signer to Farcaster",subtitle:`This will allow ${m} to add casts, likes, follows, and more on your behalf.`,onBack:s,onClose:n,watermark:!0,children:(0,e.jsxs)(V,{children:[(0,e.jsx)(z,{children:t?(0,e.jsx)(I,{url:t,size:275,squareLogoElement:g}):(0,e.jsx)(U,{children:(0,e.jsx)(F,{})})}),(0,e.jsxs)(D,{children:[(0,e.jsx)(Q,{children:"Or copy this link and paste it into a phone browser to open the Farcaster app."}),t&&(0,e.jsx)(j,{text:t,itemName:"link",color:q})]})]})}),R=o.div`
  margin-top: 24px;
`,V=o.div`
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 24px;
`,z=o.div`
  padding: 24px;
  position: relative;
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 275px;
`,D=o.div`
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 16px;
`,Q=o.div`
  font-size: 0.875rem;
  text-align: center;
  color: var(--privy-color-foreground-2);
`,U=o.div`
  position: relative;
  width: 82px;
  height: 82px;
`,ae={component:()=>{let{lastScreen:m,navigateBack:f,data:u}=C(),a=b(),{requestFarcasterSignerStatus:t,closePrivyModal:s}=S(),[n,i]=(0,r.useState)(void 0),[B,k]=(0,r.useState)(!1),[_,x]=(0,r.useState)(!1),h=(0,r.useRef)([]),c=u?.farcasterSigner;(0,r.useEffect)(()=>{let A=Date.now(),l=setInterval(async()=>{if(!c?.public_key)return clearInterval(l),void i({retryable:!0,message:"Connect failed",detail:"Something went wrong. Please try again."});c.status==="approved"&&(clearInterval(l),k(!1),x(!0),h.current.push(setTimeout(()=>s({shouldCallAuthOnSuccess:!1,isSuccess:!0}),w)));let p=await t(c?.public_key),L=Date.now()-A;p.status==="approved"?(clearInterval(l),k(!1),x(!0),h.current.push(setTimeout(()=>s({shouldCallAuthOnSuccess:!1,isSuccess:!0}),w))):L>3e5?(clearInterval(l),i({retryable:!0,message:"Connect failed",detail:"The request timed out. Try again."})):p.status==="revoked"&&(clearInterval(l),i({retryable:!0,message:"Request rejected",detail:"The request was rejected. Please try again."}))},2e3);return()=>{clearInterval(l),h.current.forEach(p=>clearTimeout(p))}},[]);let v=c?.status==="pending_approval"?c.signer_approval_url:void 0;return(0,e.jsx)(P,{appName:a.name,loading:B,success:_,errorMessage:n,connectUri:v,onBack:m?f:void 0,onClose:s,onOpenFarcaster:()=>{v&&(window.location.href=v)}})}};export{ae as FarcasterSignerStatusScreen,P as FarcasterSignerStatusView,ae as default};
