import{a as n}from"./c-RJI6KXEA.js";import{a as s,b as a,d as l}from"./c-BWLHDX22.js";import{b as g}from"./c-Y4USFN7N.js";import{f as d}from"./c-K7HT7LU7.js";var c=d(g(),1);var m=({children:o,color:i,isLoading:r,isPulsing:e,...t})=>(0,c.jsx)($,{$color:i,$isLoading:r,$isPulsing:e,...t,children:o}),$=a.span`
  padding: 0.25rem;
  font-size: 0.75rem;
  font-weight: 500;
  line-height: 1rem; /* 150% */
  border-radius: var(--privy-border-radius-xs);
  display: flex;
  align-items: center;
  ${o=>{let i,r;o.$color==="green"&&(i="var(--privy-color-success-dark)",r="var(--privy-color-success-light)"),o.$color==="red"&&(i="var(--privy-color-error)",r="var(--privy-color-error-light)"),o.$color==="gray"&&(i="var(--privy-color-foreground-2)",r="var(--privy-color-background-2)");let e=l`
      from, to {
        background-color: ${r};
      }

      50% {
        background-color: rgba(${r}, 0.8);
      }
    `;return s`
      color: ${i};
      background-color: ${r};
      ${o.$isPulsing&&s`
        animation: ${e} 3s linear infinite;
      `};
    `}}

  ${n}
`;export{m as a};
