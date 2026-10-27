import{c as K,d as X,i as Q,j as b,k as C,l as N,m as x,n as f,o as g,p as y}from"./c-TQMRD4IA.js";import{a as G}from"./c-VOX3YBRQ.js";import{a as J}from"./c-HHVY6T6T.js";import{a as I,b as O,c as F,d as R,e as A,f as $,g as P,h as L,i as z,l as B}from"./c-SAJRYZNI.js";import{B as T,C as S,E as D,y as _}from"./c-OILM665I.js";import{a as w}from"./c-4SLBV5H6.js";import{C as H,H as V,d as k,e as M,g as j,u as W,v as q}from"./c-N5TZKW5N.js";import{d as Y}from"./c-6SGKDJ7B.js";import{b as t}from"./c-BWLHDX22.js";import{g as E}from"./c-ZM4KEEHC.js";import{a as ne,b as ie}from"./c-Y4USFN7N.js";import{f as U}from"./c-K7HT7LU7.js";var d=U(ne(),1),e=U(ie(),1);var Z=class extends d.Component{static getDerivedStateFromError(){return{hasError:!0}}componentDidCatch(n,o){this.props.onError(n)}componentDidUpdate(n){n.resetKey!==this.props.resetKey&&this.state.hasError&&this.setState({hasError:!1})}render(){return this.state.hasError?null:this.props.children}constructor(...n){super(...n),this.state={hasError:!1}}};function oe(r,n,o){let i=Number(r);return!Number.isFinite(i)||i===0?`1 ${n} \u2248 ${r} ${o}`:i>=.01?`1 ${n} \u2248 ${ee(i)} ${o}`:`${ee(1/i)} ${n} \u2248 1 ${o}`}function ee(r){return r>=1e3?new Intl.NumberFormat("en-US",{maximumFractionDigits:0}).format(Math.round(r)):r>=100?new Intl.NumberFormat("en-US",{maximumFractionDigits:1}).format(r):r>=1?new Intl.NumberFormat("en-US",{maximumFractionDigits:2}).format(r):new Intl.NumberFormat("en-US",{maximumFractionDigits:4}).format(r)}function je(r,n){let o=Number(r);if(!Number.isFinite(o)||o===0)return r;let i=n!=null?o/10**n:o;return i>=1e3?new Intl.NumberFormat("en-US",{maximumFractionDigits:2}).format(i):i>=1?new Intl.NumberFormat("en-US",{maximumFractionDigits:4}).format(i):i>=1e-4?new Intl.NumberFormat("en-US",{maximumFractionDigits:6}).format(i):new Intl.NumberFormat("en-US",{maximumSignificantDigits:4}).format(i)}function We({address:r,caip2:n,config:o}){for(let i of o.currencies){let s=i.chains.find(a=>a.caip2===n&&a.address.toLowerCase()===r.toLowerCase());if(s)return{symbol:i.symbol.toUpperCase(),decimals:s.decimals}}return{symbol:r,decimals:void 0}}function qe(r,n){let o=n[r];return o?.displayName??o?.display_name??r}function He(r,n){return r.chains.filter(o=>o.can_be_relay_deposit_source===!0).map(o=>{let i=n.chains[o.caip2];return i?{caip2:o.caip2,displayName:i.displayName,iconUrl:i.iconUrl,vmType:i.vmType,currencyAddress:o.address,currencyDecimals:o.decimals}:null}).filter(o=>o!==null)}function Ve(r,n){if(!r.chains[n.destinationChain])return`Unsupported destination chain: "${n.destinationChain}". Check that the chain is in CAIP-2 format (e.g. "eip155:8453") and is supported for deposit addresses.`;let o=n.destinationCurrency.toLowerCase();return r.currencies.some(i=>i.chains.some(s=>s.caip2===n.destinationChain&&s.address.toLowerCase()===o))?null:`Unsupported destination currency "${n.destinationCurrency}" on chain "${n.destinationChain}". Check that this token address is supported on the specified chain.`}var te=new Set(["ROUTE_UNAVAILABLE","UNEXPECTED_STATE","TIMEOUT_WAITING_FOR_NEXT_ORDER","TIMEOUT_ORDER_COMPLETION","DEPOSIT_FAILED","DEPOSIT_REFUNDED","USER_EXITED","AMOUNT_TOO_LOW","INSUFFICIENT_LIQUIDITY","UNSUPPORTED_CHAIN","UNSUPPORTED_CURRENCY","UNSUPPORTED_ROUTE","NO_SWAP_ROUTES_FOUND","NO_INTERNAL_SWAP_ROUTES_FOUND","NO_QUOTES","SANCTIONED_WALLET_ADDRESS","REFUND_WALLET_CREATION_FAILED","DEPOSIT_ADDRESSES_NOT_ENABLED","NOT_AUTHENTICATED"]);function ae(r){return te.has(r)}function Ye(r){return ae(r)?r:"UNKNOWN_ERROR"}var Ke=({trackingUrl:r,onViewBlockExplorer:n,onClose:o})=>{let i=r&&n?()=>{n(),window.open(r,"_blank","noopener,noreferrer")}:void 0;return(0,e.jsx)(w,{icon:W,iconVariant:"subtle",title:"Transfer in progress",subtitle:"Your deposit was received and the transfer is now processing.",showClose:!0,onClose:o,secondaryCta:i?{label:"View on block explorer \u2197",onClick:i}:void 0,watermark:!1,children:(0,e.jsxs)(Q,{children:[(0,e.jsxs)(b,{children:[(0,e.jsx)(C,{$status:"done",children:(0,e.jsx)(k,{size:14,color:"var(--privy-color-icon-success)",strokeWidth:2})}),(0,e.jsx)(x,{children:"Deposit received"})]}),(0,e.jsx)(N,{}),(0,e.jsxs)(b,{children:[(0,e.jsx)(C,{$status:"active",children:(0,e.jsx)(se,{})}),(0,e.jsx)(x,{children:"Bridging"})]}),(0,e.jsx)(N,{}),(0,e.jsxs)(b,{children:[(0,e.jsx)(C,{$status:"pending"}),(0,e.jsx)(x,{children:"Funds arrived"})]})]})})},se=t.span`
  width: 0.75rem;
  height: 0.75rem;
  border: 2px solid var(--privy-color-foreground-3);
  border-bottom-color: transparent;
  border-radius: 50%;
  display: inline-block;
  animation: spin 1s linear infinite;

  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }
`;function de({address:r,onClick:n}){let[o,i]=(0,d.useState)(!1);return(0,e.jsx)(e.Fragment,{children:o?(0,e.jsx)(le,{onClick:()=>i(!1),style:{marginTop:"1.5rem"},children:(0,e.jsx)(J,{url:r,size:312,hideLogo:!0})}):(0,e.jsxs)(ce,{title:"Click to copy address",onClick:n,style:{marginTop:"1.5rem"},children:[(0,e.jsxs)(me,{children:[(0,e.jsx)(ue,{children:"Deposit address"}),(0,e.jsx)(pe,{children:r})]}),(0,e.jsx)(he,{children:(0,e.jsx)(fe,{type:"button",onClick:s=>{s.stopPropagation(),i(!0)},children:(0,e.jsx)(H,{size:16,color:"var(--privy-color-icon-muted)"})})})]})})}var le=t.div`
  display: flex;
  justify-content: center;
  align-items: center;
  cursor: pointer;
  overflow: hidden;
`,ce=t.div`
  display: flex;
  border-radius: var(--privy-border-radius-md);
  background: var(--privy-color-background-clicked);
  padding: 1rem;
  cursor: pointer;
  gap: 0.5rem;
`,me=t.div`
  flex: 1;
  min-width: 0;
  text-align: left;
`,ue=t.div`
  font-size: 0.75rem;
  color: var(--privy-color-icon-muted);
  line-height: 1rem;
  margin-bottom: 0.25rem;
`,pe=t.div`
  word-break: break-all;
  font-size: 0.875rem;
  font-family: ui-monospace, monospace;
  font-weight: 500;
  line-height: 1.375rem;
  color: var(--privy-color-foreground);
`,he=t.div`
  width: 1.5rem;
  flex-shrink: 0;
  display: flex;
  justify-content: center;
  padding-top: 0.25rem;
`,fe=t.button`
  && {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 1.5rem;
    height: 1.5rem;
    border: none;
    background: transparent;
    cursor: pointer;
    outline: none;
    box-shadow: none;
    border-radius: var(--privy-border-radius-xs);

    &:hover {
      background: var(--privy-color-background);
    }

    &:focus,
    &:focus-visible {
      outline: none;
      box-shadow: none;
    }
  }
`,re=r=>/^0x/i.test(r)||r.length>16;function ge({quote:r,selectedCurrency:n,selectedChain:o,destinationSymbol:i,destinationChainName:s,destinationAsset:a}){let[p,h]=(0,d.useState)(!1),l=n.symbol.toUpperCase(),c=o.displayName,m=(0,d.useRef)(null);return(0,e.jsxs)(ye,{children:[(0,e.jsxs)(ve,{onClick:(0,d.useCallback)(()=>{let u=document.getElementById("privy-modal-content");u&&(m.current&&clearTimeout(m.current),u.style.transition="none",m.current=setTimeout(()=>{u.style.transition="",m.current=null},160)),h(v=>!v)},[]),children:[(0,e.jsxs)(be,{children:[n.logoURI&&(0,e.jsx)(K,{src:n.logoURI,alt:l,style:{width:"2rem",height:"2rem"}}),o.iconUrl&&(0,e.jsx)(Ce,{src:o.iconUrl,alt:c})]}),(0,e.jsxs)(xe,{children:[(0,e.jsx)(Ee,{children:"You send"}),(0,e.jsxs)(ke,{children:[l," on ",c]})]}),(0,e.jsx)(we,{children:(0,e.jsx)(p?j:M,{size:16})})]}),(0,e.jsx)(Te,{$expanded:p,children:(0,e.jsx)(Se,{children:(0,e.jsxs)(Ne,{children:[r.indicative_rate&&(0,e.jsxs)(f,{children:[(0,e.jsx)(g,{children:"Conversion rate"}),(0,e.jsxs)(y,{style:{display:"flex",alignItems:"center",gap:"0.25rem"},children:[oe(r.indicative_rate,l,i.toUpperCase()),(0,e.jsx)(De,{content:"Estimated rate based on current market conditions. Final execution price may vary depending on transfer size and routing."})]})]}),(0,e.jsxs)(f,{children:[(0,e.jsx)(g,{children:"Receive"}),(0,e.jsxs)(y,{children:[i&&!re(i)?i.toUpperCase():re(a)?E(a):a.toUpperCase(),s?` on ${s}`:""]})]}),r.slippage_bps!=null&&(0,e.jsxs)(f,{children:[(0,e.jsx)(g,{children:"Max slippage"}),(0,e.jsxs)(y,{children:[(r.slippage_bps/100).toFixed(1),"%"]})]}),r.refund_address&&(0,e.jsxs)(f,{children:[(0,e.jsx)(g,{children:"Refund address"}),(0,e.jsx)(y,{children:(0,e.jsx)(G,{value:r.refund_address,iconOnly:!0,iconSize:11,children:E(r.refund_address,4,4)})})]})]})})}),(0,e.jsxs)(Ue,{children:[(0,e.jsx)(V,{size:16,color:"var(--privy-color-icon-muted)",style:{flexShrink:0}}),(0,e.jsxs)(_e,{children:["Only send ",(0,e.jsx)("strong",{children:l})," on ",(0,e.jsx)("strong",{children:c}),". Other assets may be lost."]})]})]})}var ye=t.div`
  border-radius: var(--privy-border-radius-md);
  border: 1px solid var(--privy-color-foreground-4);
  overflow: hidden;
`,ve=t.button`
  && {
    width: 100%;
    display: flex;
    align-items: center;
    gap: 0.75rem;
    padding: 0.75rem 1rem;
    background: transparent;
    border: none;
    cursor: pointer;
    color: var(--privy-color-foreground);
    outline: none;
    box-shadow: none;

    &:focus,
    &:focus-visible {
      outline: none;
      box-shadow: none;
    }
  }
`,be=t.span`
  position: relative;
  width: 2rem;
  height: 2rem;
  flex-shrink: 0;
`,Ce=t(X)`
  && {
    position: absolute;
    top: -0.125rem;
    right: -0.25rem;
    width: 0.75rem;
    height: 0.75rem;
    box-sizing: content-box;
    border: 1.5px solid var(--privy-color-background);
    background-color: var(--privy-color-background);
  }
`,xe=t.div`
  display: flex;
  flex-direction: column;
  align-items: flex-start;
`,Ee=t.span`
  font-size: 0.75rem;
  color: var(--privy-color-foreground-3);
  line-height: 1rem;
`,ke=t.span`
  font-size: 0.875rem;
  font-weight: 500;
  line-height: 1.25rem;
`,we=t.span`
  margin-left: auto;
  display: flex;
  align-items: center;
  justify-content: center;
  width: 1.5rem;
  height: 1.5rem;
  border-radius: var(--privy-border-radius-full);
  background-color: var(--privy-color-background-clicked);
  color: var(--privy-color-foreground-3);
`,Ne=t.div`
  display: flex;
  flex-direction: column;
  padding: 0 1rem 0.75rem;

  & > * {
    padding: 0.5rem 0;
    border-bottom: 1px solid var(--privy-color-foreground-4);
  }

  & > *:last-child {
    border-bottom: none;
  }
`,Ue=t.div`
  display: flex;
  align-items: center;
  gap: 0.5rem;
  margin: 0 0.75rem 0.75rem;
  padding: 0.625rem 0.75rem;
  border-radius: var(--privy-border-radius-sm);
  background: var(--privy-color-background-2);
`,_e=t.span`
  font-size: 0.8125rem;
  line-height: 1.25rem;
  color: var(--privy-color-icon-muted);
  text-align: left;
`,Te=t.div`
  display: grid;
  grid-template-rows: ${({$expanded:r})=>r?"1fr":"0fr"};
  transition: grid-template-rows 150ms ease-out;
`,Se=t.div`
  overflow: hidden;
`;function De({content:r}){let[n,o]=(0,d.useState)(!1),{refs:i,floatingStyles:s,context:a}=A({open:n,onOpenChange:o,placement:"top",whileElementsMounted:_,middleware:[T(6),D(),S({padding:8})]}),p=I(a,{move:!1,handleClose:B()}),h=$(a),{getReferenceProps:l,getFloatingProps:c}=P([p,h,F(a),R(a),L(a,{role:"tooltip"})]),{isMounted:m,styles:u}=z(a,{duration:150});return(0,e.jsxs)(e.Fragment,{children:[(0,e.jsx)("button",{ref:i.setReference,type:"button","aria-label":"More information about conversion rate",style:{display:"inline-flex",alignItems:"center",justifyContent:"center",padding:0,border:"none",background:"none",color:"var(--privy-color-icon-muted)",cursor:"pointer"},...l(),children:(0,e.jsx)(q,{size:14})}),m&&(0,e.jsx)(O,{root:document.getElementById("privy-modal-content")??void 0,children:(0,e.jsx)(Ie,{ref:i.setFloating,style:{...s,...u},...c(),children:r})})]})}var Ie=t.div`
  max-width: 13rem;
  padding: 0.5rem 0.625rem;
  border-radius: var(--privy-border-radius-sm, 0.375rem);
  background: var(--privy-color-foreground);
  color: var(--privy-color-background);
  font-size: 0.6875rem;
  line-height: 1rem;
  font-weight: 400;
  text-align: left;
  z-index: 10;
`,Xe=({quote:r,selectedCurrency:n,selectedChain:o,destinationSymbol:i,destinationChainName:s,destinationAsset:a,onBack:p,onClose:h})=>{let[l,c]=(0,d.useState)(!1),m=n?.symbol?.toUpperCase()??"funds",u=o?.displayName??"",v=async()=>{l||(await navigator.clipboard.writeText(r.deposit_address),c(!0),setTimeout(()=>c(!1),2e3))};return(0,e.jsxs)(w,{title:`Send ${m}${u?` on ${u}`:""}`,subtitle:"Send funds to the address below. Conversion and routing handled by Relay.",showBack:!0,onBack:p,showClose:!0,onClose:h,watermark:!1,children:[(0,e.jsx)(ge,{quote:r,selectedCurrency:n,selectedChain:o,destinationSymbol:i,destinationChainName:s,destinationAsset:a}),(0,e.jsx)(de,{address:r.deposit_address,onClick:v}),(0,e.jsx)(Y,{style:{marginTop:"1rem",marginBottom:"0.5rem",...l?{backgroundColor:"var(--privy-color-icon-success)",borderColor:"var(--privy-color-icon-success)"}:{}},onClick:v,children:l?(0,e.jsxs)(e.Fragment,{children:["Copied ",(0,e.jsx)(k,{size:16,style:{marginLeft:"0.25rem"}})]}):"Copy address"}),(0,e.jsx)(Oe,{children:"Routing and bridging are handled by Relay. Privy does not control execution timing, liquidity, or transaction outcomes."})]})},Oe=t.p`
  && {
    margin: 0.5rem 0 0;
    font-size: 0.6875rem;
    line-height: 1.125rem;
    color: var(--privy-color-icon-muted);
    text-align: center;
  }
`;export{Z as a,je as b,We as c,qe as d,He as e,Ve as f,Ye as g,Ke as h,Xe as i};
