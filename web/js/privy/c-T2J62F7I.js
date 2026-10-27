import{a as z,b as k}from"./c-ECPNWPLF.js";import{a as j}from"./c-DQDETRUI.js";import{g as P}from"./c-OAKSUO5T.js";import{a as O}from"./c-4SLBV5H6.js";import{F as M}from"./c-N5TZKW5N.js";import"./c-I2CAKQUV.js";import"./c-PVBQCY52.js";import"./c-6SGKDJ7B.js";import{b as N}from"./c-VKHXICOU.js";import{b as d}from"./c-BWLHDX22.js";import{c as x,d as C}from"./c-ZAESZNT4.js";import"./c-YE55E4G4.js";import"./c-ZM4KEEHC.js";import"./c-7QDMPFCK.js";import"./c-RGDXZPSH.js";import"./c-FKNR4ZMH.js";import{Ab as A,Ca as _,S as f,Sa as U,ob as L}from"./c-MZSQCKNV.js";import"./c-BMXE255U.js";import{b as D}from"./c-T25CEWFK.js";import{a as H,b as K}from"./c-Y4USFN7N.js";import"./c-S45QUDWV.js";import"./c-ZOH7T4WV.js";import{oa as v,v as R}from"./c-O76DOGOV.js";import"./c-4ERX45K7.js";import{f as T}from"./c-K7HT7LU7.js";var t=T(K(),1);var o=T(H(),1);var B=d.img`
  && {
    height: ${e=>e.size==="sm"?"65px":"140px"};
    width: ${e=>e.size==="sm"?"65px":"140px"};
    border-radius: 16px;
    margin-bottom: 12px;
  }
`,G=e=>{if(!R(e))return e;try{let i=v(e);return i.includes("\uFFFD")?e:i}catch{return e}},X=e=>{try{let i=D.decode(e),r=new TextDecoder().decode(i);return r.includes("\uFFFD")?e:r}catch{return e}},Y=e=>{let{types:i,primaryType:r,...l}=e.typedData;return(0,t.jsxs)(t.Fragment,{children:[(0,t.jsx)(ie,{data:l}),(0,t.jsx)(j,{text:(n=e.typedData,JSON.stringify(n,null,2)),itemName:"full payload to clipboard"})," "]});var n},Z=({method:e,messageData:i,copy:r,iconUrl:l,isLoading:n,success:u,walletProxyIsLoading:g,errorMessage:h,isCancellable:m,onSign:c,onCancel:S,onClose:p})=>(0,t.jsx)(O,{title:r.title,subtitle:r.description,showClose:!0,onClose:p,icon:M,iconVariant:"subtle",helpText:h?(0,t.jsx)(te,{children:h}):void 0,primaryCta:{label:r.buttonText,onClick:c,disabled:n||u||g,loading:n},secondaryCta:m?{label:"Not now",onClick:S,disabled:n||u||g}:void 0,watermark:!0,children:(0,t.jsxs)(P,{children:[l?(0,t.jsx)(B,{style:{alignSelf:"center"},size:"sm",src:l,alt:"app image"}):null,(0,t.jsxs)(ee,{children:[e==="personal_sign"&&(0,t.jsx)(F,{children:G(i)}),e==="eth_signTypedData_v4"&&(0,t.jsx)(Y,{typedData:i}),e==="solana_signMessage"&&(0,t.jsx)(F,{children:X(i)})]})]})}),ye={component:()=>{let{authenticated:e}=A(),{initializeWalletProxy:i,closePrivyModal:r}=_(),{navigate:l,data:n,onUserCloseViaDialogOrKeybindRef:u}=N(),[g,h]=(0,o.useState)(!0),[m,c]=(0,o.useState)(""),[S,p]=(0,o.useState)(),[E,w]=(0,o.useState)(null),[I,b]=(0,o.useState)(!1);(0,o.useEffect)(()=>{e||l("LandingScreen")},[e]),(0,o.useEffect)(()=>{i(L).then(a=>{h(!1),a||(c("An error has occurred, please try again."),p(new C(new x(m,f.E32603_DEFAULT_INTERNAL_ERROR.eipCode))))})},[]);let{method:q,data:V,confirmAndSign:J,onSuccess:Q,onFailure:W,uiOptions:s}=n.signMessage,$={title:s?.title||"Sign message",description:s?.description||"Signing this message will not cost you any fees.",buttonText:s?.buttonText||"Sign and continue"},y=a=>{a?Q(a):W(S||new C(new x("The user rejected the request.",f.E4001_USER_REJECTED_REQUEST.eipCode))),r({shouldCallAuthOnSuccess:!1}),setTimeout(()=>{w(null),c(""),p(void 0)},200)};return u.current=()=>{y(E)},(0,t.jsx)(Z,{method:q,messageData:V,copy:$,iconUrl:s?.iconUrl&&typeof s.iconUrl=="string"?s.iconUrl:void 0,isLoading:I,success:E!==null,walletProxyIsLoading:g,errorMessage:m,isCancellable:s?.isCancellable,onSign:async()=>{b(!0),c("");try{let a=await J();w(a),b(!1),setTimeout(()=>{y(a)},U)}catch(a){console.error(a),c("An error has occurred, please try again."),p(new C(new x(m,f.E32603_DEFAULT_INTERNAL_ERROR.eipCode))),b(!1)}},onCancel:()=>y(null),onClose:()=>y(E)})}},ee=d.div`
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 16px;
`,te=d.p`
  && {
    margin: 0;
    width: 100%;
    text-align: center;
    color: var(--privy-color-error-dark);
    font-size: 14px;
    line-height: 22px;
  }
`,ie=d(k)`
  margin-top: 0;
`,F=d(z)`
  margin-top: 0;
`;export{ye as SignRequestScreen,Z as SignRequestView,ye as default};
