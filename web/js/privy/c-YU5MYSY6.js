import{a as T}from"./c-5HAMH2OO.js";import{a as D,b as S}from"./c-RYCVW36N.js";import{a as w,e as n,g as l}from"./c-TQMRD4IA.js";import{d as Y}from"./c-4SCBZ7EA.js";import"./c-4SLBV5H6.js";import{L as O,o as F,w as G}from"./c-N5TZKW5N.js";import"./c-I2CAKQUV.js";import{a as _}from"./c-PVBQCY52.js";import"./c-6SGKDJ7B.js";import{k,l as x,q as L,r as E}from"./c-3A6HJROL.js";import"./c-QDFL5RZC.js";import"./c-VAJGE5VA.js";import"./c-POHRNBAL.js";import{b}from"./c-VKHXICOU.js";import{b as o}from"./c-BWLHDX22.js";import"./c-4B4DCOEF.js";import"./c-SW4LLPJ4.js";import"./c-HLLXJYUE.js";import"./c-ZM4KEEHC.js";import"./c-7QDMPFCK.js";import"./c-RGDXZPSH.js";import"./c-FKNR4ZMH.js";import{wb as A}from"./c-MZSQCKNV.js";import"./c-BMXE255U.js";import"./c-T25CEWFK.js";import{a as I,b as N}from"./c-Y4USFN7N.js";import"./c-S45QUDWV.js";import"./c-ZOH7T4WV.js";import"./c-O76DOGOV.js";import"./c-4ERX45K7.js";import{f as v}from"./c-K7HT7LU7.js";var r=v(N(),1);var t=v(I(),1);var Z={component:()=>{let e=L(),{onUserCloseViaDialogOrKeybindRef:h}=b(),R=A(),i=(0,t.useRef)(!1),m=k(),g=T(x),[j,B]=(0,t.useState)(!1),u=m?"APPLE_PAY":m===!1&&g?"GOOGLE_PAY":null,f=m===!0||m===!1&&g!==void 0,y=!e?.startFiat||f||j;(0,t.useEffect)(()=>{let C=window.setTimeout(()=>B(!0),2e3);return()=>window.clearTimeout(C)},[]),(0,t.useEffect)(()=>{e&&(i.current=!1)},[e]);let P=(0,t.useRef)(null);(0,t.useEffect)(()=>{e&&!e.error&&y&&P.current!==e&&(P.current=e,e.recordRowsViewed?.({walletPay:e.startFiat?u:void 0,walletPayTimedOut:e.startFiat?!f:void 0}))},[y,e,u,f]);let a=(0,t.useCallback)(async()=>{!i.current&&e&&(i.current=!0,E(),await e.onCancel())},[e]);if((0,t.useEffect)(()=>(h.current=a,()=>{h.current===a&&(h.current=null)}),[a,h]),!e)return null;if(e.error)return(0,r.jsx)(w,{title:"Unable to add funds",subtitle:e.error,showClose:!0,onClose:a,primaryCta:{label:"Close",onClick:a}});let p=async C=>{i.current||(i.current=!0,await e.startFiat?.(C))};return(0,r.jsx)(w,{title:"Pay with",subtitle:"Debit cards typically have higher success rates than credit cards, even with Apple Pay or Google Pay.",showClose:!0,onClose:a,children:y?(0,r.jsxs)(Y,{style:{marginTop:"1rem"},$colorScheme:R.appearance.palette.colorScheme,children:[e.startFiat&&(0,r.jsxs)(l,{onClick:()=>p("CREDIT_DEBIT_CARD"),children:[(0,r.jsx)(s,{children:(0,r.jsx)(F,{})}),(0,r.jsxs)(c,{children:[(0,r.jsx)(n,{children:"Debit or credit card"}),(0,r.jsx)(d,{children:"Less than 10 minutes"})]})]}),e.startFiat&&u==="APPLE_PAY"&&(0,r.jsxs)(l,{onClick:()=>p("APPLE_PAY"),children:[(0,r.jsx)(s,{children:(0,r.jsx)(D,{width:18,height:18})}),(0,r.jsxs)(c,{children:[(0,r.jsx)(n,{children:"Apple Pay"}),(0,r.jsx)(d,{children:"Less than 10 minutes"})]})]}),e.startFiat&&u==="GOOGLE_PAY"&&(0,r.jsxs)(l,{onClick:()=>p("GOOGLE_PAY"),children:[(0,r.jsx)(s,{children:(0,r.jsx)(S,{width:18,height:18})}),(0,r.jsxs)(c,{children:[(0,r.jsx)(n,{children:"Google Pay"}),(0,r.jsx)(d,{children:"Less than 10 minutes"})]})]}),e.startFiat&&(0,r.jsxs)(l,{onClick:()=>p("BANK"),children:[(0,r.jsx)(s,{children:(0,r.jsx)(G,{})}),(0,r.jsxs)(c,{children:[(0,r.jsx)(n,{children:"Bank account"}),(0,r.jsx)(d,{children:"1\u20132 days"})]})]}),e.startCrypto&&(0,r.jsxs)(l,{onClick:async()=>{i.current||(i.current=!0,await e.startCrypto?.())},children:[(0,r.jsx)(s,{children:(0,r.jsx)(O,{})}),(0,r.jsxs)(c,{children:[(0,r.jsx)(n,{children:"Crypto wallet or exchange"}),(0,r.jsx)(d,{children:"Instant"})]})]})]}):(0,r.jsx)(z,{children:(0,r.jsx)(_,{size:"50px"})})})}},z=o.div`
  display: flex;
  justify-content: center;
  align-items: center;
  margin-top: 1rem;
  min-height: 8rem;
`,s=o.span`
  width: 2rem;
  height: 2rem;
  border-radius: var(--privy-border-radius-full);
  background-color: var(--privy-color-background-2);
  color: var(--privy-color-icon-muted);
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
  overflow: hidden;

  svg {
    width: 1.125rem;
    height: 1.125rem;
  }
`,c=o.span`
  display: flex;
  flex-direction: column;
  align-items: flex-start;
`,d=o.span`
  font-size: 0.875rem;
  line-height: 1.25rem;
  color: var(--privy-color-foreground-3);
`;export{Z as AddFundsSelectionScreen,Z as default};
