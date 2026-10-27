import{b as n}from"./c-BWLHDX22.js";import{b as v}from"./c-Y4USFN7N.js";import{f as c}from"./c-K7HT7LU7.js";var a=c(v(),1);var p=n.a`
  && {
    color: ${({$variant:r})=>r==="underlined"?"var(--privy-color-foreground)":"var(--privy-link-navigation-color, var(--privy-color-accent))"};
    font-weight: 400;
    text-decoration: ${({$variant:r})=>r==="underlined"?"underline":"var(--privy-link-navigation-decoration, none)"};
    text-underline-offset: 4px;
    text-decoration-thickness: 1px;
    cursor: ${({$disabled:r})=>r?"not-allowed":"pointer"};
    opacity: ${({$disabled:r})=>r?.5:1};

    font-size: ${({$size:r})=>{switch(r){case"xs":return"12px";case"sm":return"14px";default:return"16px"}}};

    line-height: ${({$size:r})=>{switch(r){case"xs":return"18px";case"sm":return"22px";default:return"24px"}}};

    transition:
      color 200ms ease,
      text-decoration-color 200ms ease,
      opacity 200ms ease;

    &:hover {
      color: ${({$variant:r,$disabled:e})=>r==="underlined"?"var(--privy-color-foreground)":"var(--privy-link-navigation-color, var(--privy-color-accent))"};
      text-decoration: ${({$disabled:r})=>r?"none":"underline"};
      text-underline-offset: 4px;
    }

    &:active {
      color: ${({$variant:r,$disabled:e})=>e?r==="underlined"?"var(--privy-color-foreground)":"var(--privy-link-navigation-color, var(--privy-color-accent))":"var(--privy-color-foreground)"};
    }

    &:focus {
      outline: none;
    }

    &:focus-visible {
      outline: none;
      box-shadow: var(--privy-shadow-focus-ring);
      border-radius: 2px;
    }
  }
`,$=({size:r="md",variant:e="navigation",disabled:o=!1,as:t,children:l,onClick:s,...d})=>(0,a.jsx)(p,{as:t,$size:r,$variant:e,$disabled:o,onClick:i=>{o?i.preventDefault():s?.(i)},...d,children:l});export{$ as a};
