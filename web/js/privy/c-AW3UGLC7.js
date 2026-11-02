import{a as w,b as u,d as f}from"./c-MIGYAJ7P.js";import{c as g}from"./c-4WEDNAI6.js";import{f as v}from"./c-OAKSUO5T.js";import{a as b}from"./c-VFFQBHR2.js";import{b as n}from"./c-BWLHDX22.js";import{mb as p,wb as y}from"./c-MZSQCKNV.js";import{a as T,b as A}from"./c-Y4USFN7N.js";import{f as m}from"./c-K7HT7LU7.js";var e=m(A(),1);var d=m(T(),1);var x=({label:i,children:r,valueStyles:t})=>(0,e.jsxs)(F,{children:[(0,e.jsx)("div",{children:i}),(0,e.jsx)(z,{style:{...t},children:r})]}),F=n.div`
  display: flex;
  align-items: center;
  justify-content: space-between;
  width: 100%;

  > :first-child {
    color: var(--privy-color-foreground-3);
    text-align: left;
  }

  > :last-child {
    color: var(--privy-color-foreground-2);
    text-align: right;
  }
`,z=n.div`
  font-size: 14px;
  line-height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  border-radius: var(--privy-border-radius-full);
  background-color: var(--privy-color-background-2);
  padding: 4px 8px;
`,C=({gas:i,tokenPrice:r,tokenSymbol:t})=>(0,e.jsxs)(v,{style:{paddingBottom:"12px"},children:[(0,e.jsxs)(k,{children:[(0,e.jsx)(S,{children:"Est. Fees"}),(0,e.jsx)("div",{children:(0,e.jsx)(u,{weiQuantities:[BigInt(i)],tokenPrice:r,tokenSymbol:t})})]}),r&&(0,e.jsx)(P,{children:`${g(BigInt(i),t)}`})]}),Q=({value:i,gas:r,tokenPrice:t,tokenSymbol:o})=>{let l=BigInt(i??0)+BigInt(r);return(0,e.jsxs)(v,{children:[(0,e.jsxs)(k,{children:[(0,e.jsx)(S,{children:"Total (including fees)"}),(0,e.jsx)("div",{children:(0,e.jsx)(u,{weiQuantities:[BigInt(i||0),BigInt(r)],tokenPrice:t,tokenSymbol:o})})]}),t&&(0,e.jsx)(P,{children:g(l,o)})]})},k=n.div`
  display: flex;
  flex-direction: row;
  justify-content: space-between;
  align-items: center;
  padding-top: 4px;
`,P=n.div`
  display: flex;
  flex-direction: row;
  height: 12px;

  font-size: 12px;
  line-height: 12px;
  color: var(--privy-color-foreground-3);
  font-weight: 400;
`,S=n.div`
  font-size: 14px;
  line-height: 22.4px;
  font-weight: 400;
`,a=(0,d.createContext)(void 0),c=(0,d.createContext)(void 0),V=({defaultValue:i,children:r})=>{let[t,o]=(0,d.useState)(i||null);return(0,e.jsx)(a.Provider,{value:{activePanel:t,togglePanel:l=>{o(t===l?null:l)}},children:(0,e.jsx)(H,{children:r})})},W=({value:i,children:r})=>{let{activePanel:t,togglePanel:o}=(0,d.useContext)(a),l=t===i;return(0,e.jsx)(c.Provider,{value:{onToggle:()=>o(i),value:i},children:(0,e.jsx)(G,{isActive:l?"true":"false","data-open":String(l),children:r})})},$=({children:i})=>{let{activePanel:r}=(0,d.useContext)(a),{onToggle:t,value:o}=(0,d.useContext)(c),l=r===o;return(0,e.jsxs)(e.Fragment,{children:[(0,e.jsxs)(L,{onClick:t,"data-open":String(l),children:[(0,e.jsx)(q,{children:i}),(0,e.jsx)(K,{isactive:l?"true":"false",children:(0,e.jsx)(b,{height:"16px",width:"16px",strokeWidth:"2"})})]}),(0,e.jsx)(U,{})]})},D=({children:i})=>{let{activePanel:r}=(0,d.useContext)(a),{value:t}=(0,d.useContext)(c);return(0,e.jsx)(J,{"data-open":String(r===t),children:(0,e.jsx)(I,{children:i})})},E=({children:i})=>{let{activePanel:r}=(0,d.useContext)(a),{value:t}=(0,d.useContext)(c);return(0,e.jsx)(I,{children:typeof i=="function"?i({isActive:r===t}):i})},H=n.div`
  display: flex;
  flex-direction: column;
  width: 100%;
  gap: 8px;
`,L=n.div`
  display: flex;
  justify-content: space-between;
  align-items: center;
  width: 100%;
  cursor: pointer;
  padding-bottom: 8px;
`,U=n.div`
  width: 100%;

  && {
    border-top: 1px solid;
    border-color: var(--privy-color-foreground-4);
  }
  padding-bottom: 12px;
`,q=n.div`
  font-size: 14px;
  font-weight: 500;
  line-height: 19.6px;
  width: 100%;
  padding-right: 8px;
`,G=n.div`
  display: flex;
  flex-direction: column;
  width: 100%;
  overflow: hidden;
  padding: 12px;

  && {
    border: 1px solid;
    border-color: var(--privy-color-foreground-4);
    border-radius: var(--privy-border-radius-md);
  }
`,J=n.div`
  position: relative;
  overflow: hidden;
  transition: max-height 25ms ease-out;

  &[data-open='true'] {
    max-height: 700px;
  }

  &[data-open='false'] {
    max-height: 0;
  }
`,I=n.div`
  display: flex;
  flex-direction: column;
  gap: 12px;
  flex: 1 1 auto;
  min-height: 1px;
`,K=n.div`
  transform: ${i=>i.isactive==="true"?"rotate(180deg)":"rotate(0deg)"};
`,ee=({from:i,to:r,txn:t,transactionInfo:o,tokenPrice:l,gas:s,tokenSymbol:h})=>{let B=BigInt(t?.value||0);return(0,e.jsx)(V,{...y().render.standalone?{defaultValue:"details"}:{},children:(0,e.jsxs)(W,{value:"details",children:[(0,e.jsx)($,{children:(0,e.jsxs)(M,{children:[(0,e.jsx)("div",{children:o?.title||"Details"}),(0,e.jsx)(N,{children:(0,e.jsx)(w,{weiQuantities:[B],tokenPrice:l,tokenSymbol:h})})]})}),(0,e.jsxs)(D,{children:[(0,e.jsx)(x,{label:"From",children:(0,e.jsx)(f,{walletAddress:i,chainId:t.chainId||p,chainType:"ethereum"})}),(0,e.jsx)(x,{label:"To",children:(0,e.jsx)(f,{walletAddress:r,chainId:t.chainId||p,chainType:"ethereum"})}),o&&o.action&&(0,e.jsx)(x,{label:"Action",children:o.action}),s&&(0,e.jsx)(C,{value:t.value,gas:s,tokenPrice:l,tokenSymbol:h})]}),(0,e.jsx)(E,{children:({isActive:j})=>(0,e.jsx)(Q,{value:t.value,displayFee:j,gas:s||"0x0",tokenPrice:l,tokenSymbol:h})})]})})},M=n.div`
  display: flex;
  flex-direction: row;
  justify-content: space-between;
`,N=n.div`
  flex-shrink: 0;
  padding-left: 8px;
`;export{ee as a};
