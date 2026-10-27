import{d as a,n as l}from"./c-N5TZKW5N.js";import{f as c}from"./c-6SGKDJ7B.js";import{b as i}from"./c-BWLHDX22.js";import{g as n}from"./c-ZM4KEEHC.js";import{a as x,b as y}from"./c-Y4USFN7N.js";import{f as u}from"./c-K7HT7LU7.js";var e=u(y(),1);var t=u(x(),1);var S=({address:r,showCopyIcon:p,url:m,className:d})=>{let[o,f]=(0,t.useState)(!1);function h(s){s.stopPropagation(),navigator.clipboard.writeText(r).then(()=>f(!0)).catch(console.error)}return(0,t.useEffect)(()=>{if(o){let s=setTimeout(()=>f(!1),3e3);return()=>clearTimeout(s)}},[o]),(0,e.jsxs)(g,m?{children:[(0,e.jsx)(C,{title:r,className:d,href:`${m}/address/${r}`,target:"_blank",children:n(r)}),p&&(0,e.jsx)(c,{onClick:h,size:"sm",style:{gap:"0.375rem"},children:(0,e.jsxs)(e.Fragment,o?{children:["Copied",(0,e.jsx)(a,{size:16})]}:{children:["Copy",(0,e.jsx)(l,{size:16})]})})]}:{children:[(0,e.jsx)(z,{title:r,className:d,children:n(r)}),p&&(0,e.jsx)(c,{onClick:h,size:"sm",style:{gap:"0.375rem",fontSize:"14px"},children:(0,e.jsxs)(e.Fragment,o?{children:["Copied",(0,e.jsx)(a,{size:14})]}:{children:["Copy",(0,e.jsx)(l,{size:14})]})})]})},g=i.span`
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
`,z=i.span`
  font-size: 14px;
  font-weight: 500;
  color: var(--privy-color-foreground);
`,C=i.a`
  font-size: 14px;
  color: var(--privy-color-foreground);
  text-decoration: none;

  &:hover {
    text-decoration: underline;
  }
`;export{S as a};
