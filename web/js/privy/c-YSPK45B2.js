import{a as we}from"./c-X3EZWWFF.js";import{a as ve}from"./c-XM7QKX4Q.js";import{a as be}from"./c-HCQ2IGGY.js";import{a as xe}from"./c-5CFZB2OQ.js";import{a as b}from"./c-QQ2AEEUS.js";import{a as _,b as fe}from"./c-5UBEEEFD.js";import{a as ge}from"./c-VYKYNVJJ.js";import{b as ue}from"./c-TL3NQV32.js";import{a as re}from"./c-5N3JOPRH.js";import{a as ne}from"./c-527X7JVK.js";import{b as ke}from"./c-OYO3VIHG.js";import{a as L,b as n,c as i,d as ye,e as o}from"./c-LKUKMMOJ.js";import{a as ee}from"./c-RJI6KXEA.js";import{a}from"./c-JHE6C6B4.js";import{a as Z}from"./c-VFFQBHR2.js";import{a as F}from"./c-QE6E4VL4.js";import{a as he,d as B,i as me,j as V,l as Y,m as pe}from"./c-6SGKDJ7B.js";import{b as K}from"./c-BDIKRNDT.js";import{b as d}from"./c-BWLHDX22.js";import{Ca as ce,O as de,sa as X,wb as G}from"./c-MZSQCKNV.js";import{a as Ge,b as Ke}from"./c-Y4USFN7N.js";import{Ia as se}from"./c-O76DOGOV.js";import{f as ae}from"./c-K7HT7LU7.js";var e=ae(Ke(),1);var R=ae(Ge(),1);var ie=d(i)`
  cursor: pointer;
  display: inline-flex;
  gap: 8px;
  align-items: center;
  color: var(--privy-color-accent);
  svg {
    fill: var(--privy-color-accent);
  }
`;var Te=({iconUrl:s,value:c,symbol:l,usdValue:u,nftName:T,nftCount:f,decimals:t,$isLoading:p})=>{if(p)return(0,e.jsx)(Ie,{$isLoading:p});let y=c&&u&&t?function(I,$,O){let A=parseFloat(I),m=parseFloat(O);if(A===0||m===0||Number.isNaN(A)||Number.isNaN(m))return I;let v=Math.ceil(-Math.log10(.01/(m/A))),k=Math.pow(10,v=Math.max(v=Math.min(v,$),1)),S=+(Math.floor(A*k)/k).toFixed(v).replace(/\.?0+$/,"");return Intl.NumberFormat(void 0,{maximumFractionDigits:$}).format(S)}(c,t,u):c;return(0,e.jsxs)("div",{children:[(0,e.jsxs)(Ie,{$isLoading:p,children:[s&&(0,e.jsx)(_e,{src:s,alt:"Token icon"}),f&&f>1?f+"x":void 0," ",T,y," ",l]}),u&&(0,e.jsxs)(Ye,{$isLoading:p,children:["$",u]})]})},Ie=d.span`
  color: var(--privy-color-foreground);
  font-size: 0.875rem;
  font-weight: 500;
  line-height: 1.375rem;
  word-break: break-all;
  text-align: right;
  display: flex;
  justify-content: flex-end;

  /**
   * @NOTE This is a code smell anti-pattern for styling components.
   * We are mixing JSX definitions with styled-components CSS definitions.
   * This is not ideal and should be refactored in the future to separate concerns.
   * This is also hard to read, as it makes it difficult to understand the structure
   * of the component and its styles by viewing the JSX.
   */

  ${ee}
`,Ye=d.span`
  color: var(--privy-color-foreground-2);
  font-size: 12px;
  font-weight: 400;
  line-height: 18px;
  word-break: break-all;
  text-align: right;
  display: flex;
  justify-content: flex-end;

  ${ee}
`,_e=d.img`
  height: 14px;
  width: 14px;
  margin-right: 4px;
  object-fit: contain;
`,Ze=s=>{let{chain:c,transactionDetails:l,isTokenContractInfoLoading:u,symbol:T}=s,{action:f,functionName:t}=l;return(0,e.jsx)(ke,{children:(0,e.jsxs)(L,{children:[f!=="transaction"&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Action"}),(0,e.jsx)(o,{children:t})]}),t==="mint"&&"args"in l&&l.args.filter(p=>p).map((p,y)=>(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:`Param ${y}`}),(0,e.jsx)(o,{children:typeof p=="string"&&se(p)?(0,e.jsx)(a,{address:p,url:c?.blockExplorers?.default?.url,showCopyIcon:!1}):p?.toString()})]},y)),t==="setApprovalForAll"&&l.operator&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Operator"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:l.operator,url:c?.blockExplorers?.default?.url,showCopyIcon:!1})})]}),t==="setApprovalForAll"&&l.approved!==void 0&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Set approval to"}),(0,e.jsx)(o,{children:l.approved?"true":"false"})]}),t==="transfer"||t==="transferWithMemo"||t==="transferFrom"||t==="safeTransferFrom"||t==="approve"?(0,e.jsxs)(e.Fragment,{children:["formattedAmount"in l&&l.formattedAmount&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Amount"}),(0,e.jsxs)(o,{$isLoading:u,children:[l.formattedAmount," ",T]})]}),"tokenId"in l&&l.tokenId&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Token ID"}),(0,e.jsx)(o,{children:l.tokenId.toString()})]})]}):null,t==="safeBatchTransferFrom"&&(0,e.jsxs)(e.Fragment,{children:["amounts"in l&&l.amounts&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Amounts"}),(0,e.jsx)(o,{children:l.amounts.join(", ")})]}),"tokenIds"in l&&l.tokenIds&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Token IDs"}),(0,e.jsx)(o,{children:l.tokenIds.join(", ")})]})]}),t==="approve"&&l.spender&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Spender"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:l.spender,url:c?.blockExplorers?.default?.url,showCopyIcon:!1})})]}),(t==="transferFrom"||t==="safeTransferFrom"||t==="safeBatchTransferFrom")&&l.transferFrom&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Transferring from"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:l.transferFrom,url:c?.blockExplorers?.default?.url,showCopyIcon:!1})})]}),(t==="transferFrom"||t==="safeTransferFrom"||t==="safeBatchTransferFrom")&&l.transferTo&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Transferring to"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:l.transferTo,url:c?.blockExplorers?.default?.url,showCopyIcon:!1})})]})]})})},er=({variant:s,setPreventMaliciousTransaction:c,colorScheme:l="light",preventMaliciousTransaction:u})=>s==="warn"?(0,e.jsx)(Ae,{children:(0,e.jsxs)(ve,{theme:l,children:[(0,e.jsx)("span",{style:{fontWeight:"500"},children:"Warning: Suspicious transaction"}),(0,e.jsx)("br",{}),"This has been flagged as a potentially deceptive request. Approving could put your assets or funds at risk."]})}):s==="error"?(0,e.jsx)(e.Fragment,{children:(0,e.jsxs)(Ae,{children:[(0,e.jsx)(we,{theme:l,children:(0,e.jsxs)("div",{children:[(0,e.jsx)("strong",{children:"This is a malicious transaction"}),(0,e.jsx)("br",{}),"This transaction transfers tokens to a known malicious address. Proceeding may result in the loss of valuable assets."]})}),(0,e.jsxs)(rr,{children:[(0,e.jsx)(be,{color:"var(--privy-color-error)",checked:!u,readOnly:!0,onClick:()=>c(!u)}),(0,e.jsx)("span",{children:"I understand and want to proceed anyways."})]})]})}):null,Ae=d.div`
  margin-top: 1.5rem;
`,rr=d.div`
  display: flex;
  align-items: center;
  gap: 0.5rem;
  margin-top: 0.75rem;
`,nr=({transactionIndex:s,maxIndex:c})=>typeof s!="number"||c===0?"":` (${s+1} / ${c+1})`,Jr=({img:s,submitError:c,prepareError:l,onClose:u,action:T,title:f,subtitle:t,to:p,tokenAddress:y,network:I,missingFunds:$,fee:O,from:A,cta:m,disabled:v,chain:k,isSubmitting:S,isPreparing:g,isTokenPriceLoading:E,isTokenContractInfoLoading:P,isSponsored:j,symbol:U,balance:M,onClick:N,transactionDetails:C,transactionIndex:z,maxIndex:W,onBack:r,chainName:x,validation:q,hasScanDetails:oe,setIsScanDetailsOpen:Pe,preventMaliciousTransaction:je,setPreventMaliciousTransaction:Me,tokensSent:te,tokensReceived:J,isScanning:ze,isCancellable:Be,functionName:Ve})=>{let{showTransactionDetails:H,setShowTransactionDetails:Re,hasMoreDetails:Ue,isErc20Ish:We}=(h=>{let[D,He]=(0,R.useState)(!1),Q=!0,le=!1;return(!h||h.isErc20Ish||h.action==="transaction")&&(Q=!1),Q&&(le=Object.entries(h||{}).some(([Qe,Xe])=>Xe&&!["action","isErc20Ish","isNFTIsh"].includes(Qe))),{showTransactionDetails:D,setShowTransactionDetails:He,hasMoreDetails:Q&&le,isErc20Ish:h?.isErc20Ish}})(C),qe=G(),Je=We&&P||g||E||ze;return(0,e.jsxs)(e.Fragment,{children:[(0,e.jsx)(V,{onClose:u,backFn:r}),s&&(0,e.jsx)(De,{children:s}),(0,e.jsxs)(ne,{style:{marginTop:s?"1.5rem":0},children:[f,(0,e.jsx)(nr,{maxIndex:W,transactionIndex:z})]}),(0,e.jsx)(re,{children:t}),(0,e.jsxs)(L,{style:{marginTop:"2rem"},children:[(!!te[0]||Je)&&(0,e.jsxs)(n,{children:[J.length>0?(0,e.jsx)(i,{children:"Send"}):(0,e.jsx)(i,{children:T==="approve"?"Approval amount":"Amount"}),(0,e.jsx)("div",{className:"flex flex-col",children:te.map((h,D)=>(0,e.jsx)(Te,{iconUrl:h.iconUrl,value:Ve==="setApprovalForAll"?"All":h.value,usdValue:h.usdValue,symbol:h.symbol,nftName:h.nftName,nftCount:h.nftCount,decimals:h.decimals},D))})]}),J.length>0&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Receive"}),(0,e.jsx)("div",{className:"flex flex-col",children:J.map((h,D)=>(0,e.jsx)(Te,{iconUrl:h.iconUrl,value:h.value,usdValue:h.usdValue,symbol:h.symbol,nftName:h.nftName,nftCount:h.nftCount,decimals:h.decimals},D))})]}),C&&"spender"in C&&C?.spender?(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Spender"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:C.spender,url:k?.blockExplorers?.default?.url})})]}):null,p&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"To"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:p,url:k?.blockExplorers?.default?.url,showCopyIcon:!0})})]}),y&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Token address"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:y,url:k?.blockExplorers?.default?.url})})]}),(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Network"}),(0,e.jsx)(o,{children:I})]}),(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Estimated fee"}),(0,e.jsx)(o,{$isLoading:g||E||j===void 0,children:j?(0,e.jsxs)(Fe,{children:[(0,e.jsxs)(Le,{children:["Sponsored by ",qe.name]}),(0,e.jsx)(_,{height:16,width:16})]}):O})]}),Ue&&!oe&&(0,e.jsxs)(e.Fragment,{children:[(0,e.jsx)(n,{className:"cursor-pointer",onClick:()=>Re(!H),children:(0,e.jsxs)(ye,{className:"flex items-center gap-x-1",children:["Details"," ",(0,e.jsx)(Z,{style:{width:"0.75rem",marginLeft:"0.25rem",transform:H?"rotate(180deg)":void 0}})]})}),H&&C&&(0,e.jsx)(Ze,{action:T,chain:k,transactionDetails:C,isTokenContractInfoLoading:P,symbol:U})]}),oe&&(0,e.jsx)(n,{children:(0,e.jsxs)(ie,{onClick:()=>Pe(!0),children:[(0,e.jsx)("span",{className:"text-color-primary",children:"Details"}),(0,e.jsx)(he,{height:"14px",width:"14px",strokeWidth:"2"})]})})]}),(0,e.jsx)(K,{}),c?(0,e.jsx)(F,{style:{marginTop:"2rem"},children:c.message}):l&&z===0?(0,e.jsx)(F,{style:{marginTop:"2rem"},children:l.shortMessage??Ne}):null,(0,e.jsx)(er,{variant:q,preventMaliciousTransaction:je,setPreventMaliciousTransaction:Me}),(0,e.jsx)(Ee,{$useSmallMargins:!(!l&&!c&&q!=="warn"&&q!=="error"),address:A,balance:M,errMsg:g||l||c||!$?void 0:`Add funds on ${k?.name??x} to complete transaction.`}),(0,e.jsx)(B,{style:{marginTop:"1rem"},loading:S,disabled:v||g,onClick:N,children:m}),Be&&(0,e.jsx)(me,{style:{marginTop:"1rem"},onClick:u,isSubmitting:!1,children:"Not now"}),(0,e.jsx)(Y,{})]})},Hr=({img:s,title:c,subtitle:l,cta:u,instructions:T,network:f,blockExplorerUrl:t,isMissingFunds:p,submitError:y,parseError:I,total:$,swap:O,transactingWalletAddress:A,fee:m,balance:v,disabled:k,isSubmitting:S,isPreparing:g,isTokenPriceLoading:E,onClick:P,onClose:j,onBack:U,isSponsored:M})=>{let N=g||E,[C,z]=(0,R.useState)(!1),W=G();return(0,e.jsxs)(e.Fragment,{children:[(0,e.jsx)(V,{onClose:j,backFn:U}),s&&(0,e.jsx)(De,{children:s}),(0,e.jsx)(ne,{style:{marginTop:s?"1.5rem":0},children:c}),(0,e.jsx)(re,{children:l}),(0,e.jsxs)(L,{style:{marginTop:"2rem",marginBottom:".5rem"},children:[($||N)&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Amount"}),(0,e.jsx)(o,{$isLoading:N,children:$})]}),O&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Swap"}),(0,e.jsx)(o,{children:O})]}),f&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Network"}),(0,e.jsx)(o,{children:f})]}),(m||N||M!==void 0)&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Estimated fee"}),(0,e.jsx)(o,{$isLoading:N,children:M&&!N?(0,e.jsxs)(Fe,{children:[(0,e.jsxs)(Le,{children:["Sponsored by ",W.name]}),(0,e.jsx)(_,{height:16,width:16})]}):m})]})]}),(0,e.jsx)(n,{children:(0,e.jsxs)(ie,{onClick:()=>z(r=>!r),children:[(0,e.jsx)("span",{children:"Advanced"}),(0,e.jsx)(Z,{height:"16px",width:"16px",strokeWidth:"2",style:{transition:"all 300ms",transform:C?"rotate(180deg)":void 0}})]})}),C&&(0,e.jsx)(e.Fragment,{children:T.map((r,x)=>r.type==="sol-transfer"?(0,e.jsxs)(w,{children:[(0,e.jsx)(n,{children:(0,e.jsxs)(b,{children:["Transfer ",r.withSeed?"with seed":""]})}),(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Amount"}),(0,e.jsxs)(o,{children:[X({amount:r.value,decimals:r.token.decimals})," ",r.token.symbol]})]}),!!r.toAccount&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Destination"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:r.toAccount,url:t})})]})]},x):r.type==="spl-transfer"?(0,e.jsxs)(w,{children:[(0,e.jsx)(n,{children:(0,e.jsxs)(b,{children:["Transfer ",r.token.symbol]})}),(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Amount"}),(0,e.jsx)(o,{children:r.value.toString()})]}),!!r.fromAta&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Source"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:r.fromAta,url:t})})]}),!!r.toAta&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Destination"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:r.toAta,url:t})})]}),!!r.token.address&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Token"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:r.token.address,url:t})})]})]},x):r.type==="ata-creation"?(0,e.jsxs)(w,{children:[(0,e.jsx)(n,{children:(0,e.jsx)(b,{children:"Create token account"})}),(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Program ID"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:r.program,url:t})})]}),!!r.owner&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Owner"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:r.owner,url:t})})]})]},x):r.type==="create-account"?(0,e.jsxs)(w,{children:[(0,e.jsx)(n,{children:(0,e.jsxs)(b,{children:["Create account ",r.withSeed?"with seed":""]})}),!!r.account&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Account"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:r.account,url:t})})]}),(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Amount"}),(0,e.jsxs)(o,{children:[X({amount:r.value,decimals:9})," SOL"]})]})]},x):r.type==="spl-init-account"?(0,e.jsxs)(w,{children:[(0,e.jsx)(n,{children:(0,e.jsx)(b,{children:"Initialize token account"})}),!!r.account&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Account"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:r.account,url:t})})]}),!!r.mint&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Mint"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:r.mint,url:t})})]}),!!r.owner&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Owner"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:r.owner,url:t})})]})]},x):r.type==="spl-close-account"?(0,e.jsxs)(w,{children:[(0,e.jsx)(n,{children:(0,e.jsx)(b,{children:"Close token account"})}),!!r.source&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Source"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:r.source,url:t})})]}),!!r.destination&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Destination"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:r.destination,url:t})})]}),!!r.owner&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Owner"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:r.owner,url:t})})]})]},x):r.type==="spl-sync-native"?(0,e.jsxs)(w,{children:[(0,e.jsx)(n,{children:(0,e.jsx)(b,{children:"Sync native"})}),(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Program ID"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:r.program,url:t})})]})]},x):r.type==="raydium-swap-base-input"?(0,e.jsxs)(w,{children:[(0,e.jsx)(n,{children:(0,e.jsxs)(b,{children:["Raydium swap"," ",r.tokenIn&&r.tokenOut?`${r.tokenIn.symbol} \u2192 ${r.tokenOut.symbol}`:""]})}),(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Amount in"}),(0,e.jsx)(o,{children:r.amountIn.toString()})]}),(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Minimum amount out"}),(0,e.jsx)(o,{children:r.minimumAmountOut.toString()})]}),r.mintIn&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Token in"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:r.mintIn,url:t})})]}),r.mintOut&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Token out"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:r.mintOut,url:t})})]})]},x):r.type==="raydium-swap-base-output"?(0,e.jsxs)(w,{children:[(0,e.jsx)(n,{children:(0,e.jsxs)(b,{children:["Raydium swap"," ",r.tokenIn&&r.tokenOut?`${r.tokenIn.symbol} \u2192 ${r.tokenOut.symbol}`:""]})}),(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Max amount in"}),(0,e.jsx)(o,{children:r.maxAmountIn.toString()})]}),(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Amount out"}),(0,e.jsx)(o,{children:r.amountOut.toString()})]}),r.mintIn&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Token in"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:r.mintIn,url:t})})]}),r.mintOut&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Token out"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:r.mintOut,url:t})})]})]},x):r.type==="jupiter-swap-shared-accounts-route"?(0,e.jsxs)(w,{children:[(0,e.jsx)(n,{children:(0,e.jsxs)(b,{children:["Jupiter swap"," ",r.tokenIn&&r.tokenOut?`${r.tokenIn.symbol} \u2192 ${r.tokenOut.symbol}`:""]})}),(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"In amount"}),(0,e.jsx)(o,{children:r.inAmount.toString()})]}),(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Quoted out amount"}),(0,e.jsx)(o,{children:r.quotedOutAmount.toString()})]}),r.mintIn&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Token in"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:r.mintIn,url:t})})]}),r.mintOut&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Token out"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:r.mintOut,url:t})})]})]},x):r.type==="jupiter-swap-exact-out-route"?(0,e.jsxs)(w,{children:[(0,e.jsx)(n,{children:(0,e.jsxs)(b,{children:["Jupiter swap"," ",r.tokenIn&&r.tokenOut?`${r.tokenIn.symbol} \u2192 ${r.tokenOut.symbol}`:""]})}),(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Quoted in amount"}),(0,e.jsx)(o,{children:r.quotedInAmount.toString()})]}),(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Amount out"}),(0,e.jsx)(o,{children:r.outAmount.toString()})]}),r.mintIn&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Token in"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:r.mintIn,url:t})})]}),r.mintOut&&(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Token out"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:r.mintOut,url:t})})]})]},x):(0,e.jsxs)(w,{children:[(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Program ID"}),(0,e.jsx)(o,{children:(0,e.jsx)(a,{address:r.program,url:t})})]}),(0,e.jsxs)(n,{children:[(0,e.jsx)(i,{children:"Data"}),(0,e.jsx)(o,{children:r.discriminator})]})]},x))}),(0,e.jsx)(K,{}),y?(0,e.jsx)(F,{style:{marginTop:"2rem"},children:y.message}):I?(0,e.jsx)(F,{style:{marginTop:"2rem"},children:Ne}):null,(0,e.jsx)(Ee,{$useSmallMargins:!(!I&&!y),title:"",address:A,balance:v,errMsg:g||I||y||!p?void 0:"Add funds on Solana to complete transaction."}),(0,e.jsx)(B,{style:{marginTop:"1rem"},loading:S,disabled:k||g,onClick:P,children:u}),(0,e.jsx)(Y,{})]})},Ee=d(xe)`
  ${s=>s.$useSmallMargins?"margin-top: 0.5rem;":"margin-top: 2rem;"}
`,w=d(L)`
  margin-top: 0.5rem;
  border: 1px solid var(--privy-color-foreground-4);
  border-radius: var(--privy-border-radius-sm);
  padding: 0.5rem;
`,Ne="There was an error preparing your transaction. Your transaction request will likely fail.",De=d.div`
  display: flex;
  width: 100%;
  justify-content: center;
  max-height: 40px;

  > img {
    object-fit: contain;
    border-radius: var(--privy-border-radius-sm);
  }
`,Fe=d.span`
  display: inline-flex;
  align-items: center;
  gap: 0.3rem;
`,Le=d.span`
  font-size: 14px;
  font-weight: 500;
  color: var(--privy-color-foreground);
`,Se=s=>s?.code===de.COMPLIANCE_BLOCKED,ir=()=>(0,e.jsxs)(ar,{children:[(0,e.jsx)(dr,{}),(0,e.jsx)(sr,{})]}),Qr=({transactionError:s,chainId:c,onClose:l,onRetry:u,chainType:T,transactionHash:f})=>{let{chains:t}=ce(),[p,y]=(0,R.useState)(!1),{errorCode:I,errorMessage:$}=((m,v)=>{if(v==="ethereum")return Se(m)?{errorCode:"Transaction blocked",errorMessage:m.message}:{errorCode:m.details??m.message,errorMessage:m.shortMessage};let k=m.txSignature,S=m?.transactionMessage||"Something went wrong.";if(Array.isArray(m.logs)){let g=m.logs.find(E=>/insufficient (lamports|funds)/gi.test(E));g&&(S=g)}return{transactionHash:k,errorMessage:S}})(s,T),O=Se(s),A=(({chains:m,chainId:v,chainType:k,transactionHash:S})=>k==="ethereum"?m.find(g=>g.id===v)?.blockExplorers?.default.url??"https://etherscan.io":function(g,E){return`https://explorer.solana.com/tx/${g}?chain=${E}`}(S||"",v))({chains:t,chainId:c,chainType:T,transactionHash:f});return(0,e.jsxs)(e.Fragment,{children:[(0,e.jsx)(V,{onClose:l}),(0,e.jsxs)(or,{children:[(0,e.jsx)(ir,{}),(0,e.jsx)(tr,{children:I}),(0,e.jsx)(lr,{children:O?"This transaction cannot be completed.":"Please try again."}),(0,e.jsxs)($e,{children:[(0,e.jsx)(Ce,{children:"Error message"}),(0,e.jsx)(Oe,{$clickable:!1,children:$})]}),f&&(0,e.jsxs)($e,{children:[(0,e.jsx)(Ce,{children:"Transaction hash"}),(0,e.jsxs)(hr,{children:["Copy this hash to view details about the transaction on a"," ",(0,e.jsx)("u",{children:(0,e.jsx)("a",{href:A,children:"block explorer"})}),"."]}),(0,e.jsxs)(Oe,{$clickable:!0,onClick:async()=>{await navigator.clipboard.writeText(f),y(!0)},children:[f,(0,e.jsx)(ur,{clicked:p})]})]}),!O&&(0,e.jsx)(cr,{onClick:()=>u({resetNonce:!!f}),children:"Retry transaction"})]}),(0,e.jsx)(pe,{})]})},or=d.div`
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
`,tr=d.span`
  color: var(--privy-color-foreground);
  font-size: 1.125rem;
  font-weight: 500;
  line-height: 1.25rem; /* 111.111% */
  text-align: center;
  margin: 10px;
`,lr=d.span`
  margin-top: 4px;
  margin-bottom: 10px;
  color: var(--privy-color-foreground-3);
  text-align: center;

  font-size: 0.875rem;
  font-style: normal;
  font-weight: 400;
  line-height: 20px; /* 142.857% */
  letter-spacing: -0.008px;
`,ar=d.div`
  position: relative;
  width: 60px;
  height: 60px;
  margin: 10px;
  display: flex;
  justify-content: center;
  align-items: center;
`,sr=d(ge)`
  position: absolute;
  width: 35px;
  height: 35px;
  color: var(--privy-color-error);
`,dr=d.div`
  position: absolute;
  width: 60px;
  height: 60px;
  border-radius: 50%;
  background-color: var(--privy-color-error);
  opacity: 0.1;
`,cr=d(B)`
  && {
    margin-top: 24px;
  }
  transition:
    color 350ms ease,
    background-color 350ms ease;
`,Ce=d.span`
  width: 100%;
  text-align: left;
  font-size: 0.825rem;
  color: var(--privy-color-foreground);
  padding: 4px;
`,$e=d.div`
  width: 100%;
  margin: 5px;
  display: flex;
  flex-direction: column;
  justify-content: center;
  align-items: center;
`,hr=d.text`
  position: relative;
  width: 100%;
  padding: 5px;
  font-size: 0.8rem;
  color: var(--privy-color-foreground-3);
  text-align: left;
  overflow-wrap: break-word;
`,Oe=d.span`
  position: relative;
  width: 100%;
  background-color: var(--privy-color-background-2);
  padding: 8px 12px;
  border-radius: 10px;
  margin-top: 5px;
  font-size: 14px;
  color: var(--privy-color-foreground-3);
  text-align: left;
  overflow-wrap: break-word;
  ${s=>s.$clickable&&`cursor: pointer;
  transition: background-color 0.3s;
  padding-right: 45px;

  &:hover {
    background-color: var(--privy-color-foreground-4);
  }`}
`,mr=d(fe)`
  position: absolute;
  top: 13px;
  right: 13px;
  width: 24px;
  height: 24px;
`,pr=d(ue)`
  position: absolute;
  top: 13px;
  right: 13px;
  width: 24px;
  height: 24px;
`,ur=({clicked:s})=>(0,e.jsx)(s?pr:mr,{});export{Jr as a,Hr as b,Qr as c};
