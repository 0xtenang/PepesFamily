import{c as s}from"./c-VAJGE5VA.js";import{a as v,b as l}from"./c-BWLHDX22.js";import{a as x}from"./c-YE55E4G4.js";import{a as c}from"./c-HLLXJYUE.js";import{o as y,v as i}from"./c-ZM4KEEHC.js";import{Ca as h,wb as m,zb as d}from"./c-MZSQCKNV.js";import{a as T,b as z}from"./c-Y4USFN7N.js";import{pa as g}from"./c-O76DOGOV.js";import{f}from"./c-K7HT7LU7.js";var r=f(T(),1);var b=f(z(),1);var D=e=>{let[t,o]=(0,r.useState)("auto");return(0,r.useEffect)(()=>{let n=new ResizeObserver(a=>{o(a[0]?.contentRect.height??"auto")});return e.current&&n.observe(e.current),()=>{e.current&&n.unobserve(e.current)}},[e.current]),t},F=l.div`
  text-align: left;
  flex-grow: 1;
`,G=l.div`
  display: flex;
  flex-direction: column;
  justify-content: flex-end;
  flex-grow: 1;
`,I=l.div`
  display: flex;
  flex-direction: column;
  gap: 8px;

  /* for Internet Explorer, Edge */
  -ms-overflow-style: none;

  /* for Firefox */
  scrollbar-width: none;

  /* for Chrome, Safari, and Opera */
  &::-webkit-scrollbar {
    display: none;
  }
`,L=l(I)`
  ${e=>e.$colorScheme==="light"?"background: linear-gradient(var(--privy-color-background), var(--privy-color-background) 70%) bottom, linear-gradient(rgba(0, 0, 0, 0) 20%, rgba(0, 0, 0, 0.06)) bottom;":e.$colorScheme==="dark"?"background: linear-gradient(var(--privy-color-background), var(--privy-color-background) 70%) bottom, linear-gradient(rgba(255, 255, 255, 0) 20%, rgba(255, 255, 255, 0.06)) bottom;":void 0}

  background-repeat: no-repeat;
  background-size:
    100% 32px,
    100% 16px;
  background-attachment: local, scroll;
  max-height: 400px;
  overflow-y: auto;
  scrollbar-width: none;
  padding: 3px;
`,k=v`
  && {
    width: 100%;
    font-size: 16px;
    line-height: 24px;
    min-height: 56px;

    /* Tablet and Up */
    @media (min-width: 440px) {
      font-size: 14px;
    }

    display: flex;
    gap: 12px;
    align-items: center;
    color: var(--privy-color-foreground);

    padding: 10px 12px;
    border: 1px solid var(--privy-color-foreground-4) !important;
    border-radius: var(--privy-border-radius-md);
    transition: background-color 200ms ease;

    cursor: pointer;

    &:hover {
      background-color: var(--privy-color-background-2);
    }

    &:disabled {
      cursor: pointer;
      background-color: var(--privy-color-background-2);
    }
  }
`,q=l.div`
  text-align: center;
  font-size: 14px;
  margin-bottom: 24px;
`,B=l.button.attrs({className:"login-method-button"})`
  ${k}
`;l.a`
  ${k}
`;var J=l.div`
  width: 32px;
  height: 32px;
  border-radius: ${e=>e.$fullSize?"0":"4px"};
  background: ${e=>e.$fullSize?"transparent":"var(--privy-color-background-2)"};
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;

  svg {
    width: ${e=>e.$fullSize?"32px":"18px"};
    height: ${e=>e.$fullSize?"32px":"18px"};
    color: ${e=>e.$fullSize?"inherit":"var(--privy-color-icon-muted)"};
  }
`,K=l.div`
  width: 100%;
  height: 100%;
  min-height: inherit;
  display: flex;
  flex-direction: column;
  ${e=>e.$if?"display: none;":""}
`,Q=l.div`
  width: 100%;
  height: 100%;
  padding: ${e=>e.$withPadding?"64px 0px":"0px"};
`,V=l.div`
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  margin-bottom: 32px;
  gap: 12px;
  & h3 {
    font-size: 18px;
    font-style: normal;
    font-weight: 600;
    line-height: 24px;
  }
  & p {
    max-width: 300px;
    font-size: 14px;
    font-style: normal;
    font-weight: 400;
    line-height: 20px;
  }
`;async function X(e,t,o){if(!t.shouldEnforceDefaultChainOnConnect)return;let n=Number(e.chainId.replace("eip155:",""));if(!t.chains.find(a=>a.id===n)&&(e.connectorType!=="wallet_connect_v2"||e.walletClientType!=="metamask")){o?.();try{await e.switchChain(t.defaultChain.id),e.chainId=y(g(t.defaultChain.id))}catch{x.warn("Unable to switch to default chain after connect",{chainId:t.defaultChain.id})}}}var $=(0,r.createContext)({}),Y=({children:e})=>{let t=m(),[o,n]=(0,r.useState)({});return s("login",{onComplete:({loginAccount:a})=>{a&&a.type!=="passkey"&&a.type!=="cross_app"&&(a.type!=="wallet"||a.walletClientType!=="privy")&&(i.put(w(t.id),a.type),a.type==="wallet"?(i.put(p(t.id),a.walletClientType),i.put(u(t.id),a.chainType),n({accountType:a.type,walletClientType:a.walletClientType,chainType:a.chainType})):(i.del(p(t.id)),i.del(u(t.id)),n({accountType:a.type})))}}),(0,r.useEffect)(()=>{if(!t.id)return;let a=i.get(w(t.id)),S=i.get(p(t.id)),C=i.get(u(t.id));a&&n(a==="wallet"?{accountType:a,walletClientType:S,chainType:C}:{accountType:a})},[t.id]),(0,b.jsx)($.Provider,{value:o,children:e})},w=e=>`privy:${e}:recent-login-method`,p=e=>`privy:${e}:recent-login-wallet-client`,u=e=>`privy:${e}:recent-login-chain-type`,Z=()=>(0,r.useContext)($),ee=e=>{s("fundWallet",e);let{fundWallet:t}=h();return{fundWallet:({address:o,options:n})=>t(o,n)}};function te(e){let{login:t}=(0,r.useContext)(d);return s("login",e),{login:t}}function ae(e){let{logout:t}=(0,r.useContext)(d);return s("logout",e),{logout:t}}var W=c(()=>({isModalOpen:!1,resolvers:null})),re=c(()=>({}));var ne=({address:e,client:t,appId:o})=>{let n=`${t}:${e}`;o&&i.put(j(o),n),W.setState({wallet:n})};var j=e=>`privy:${e}:active-wallet-connection`;export{D as a,F as b,G as c,I as d,L as e,q as f,B as g,J as h,K as i,Q as j,V as k,X as l,Y as m,Z as n,ee as o,te as p,ae as q,ne as r};
