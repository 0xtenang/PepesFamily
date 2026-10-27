import{b as e}from"./c-BWLHDX22.js";import{b as t}from"./c-Y4USFN7N.js";import{f as n}from"./c-K7HT7LU7.js";var i=n(t(),1);var v=({size:r,centerIcon:s})=>(0,i.jsx)(a,{$size:r,children:(0,i.jsxs)(o,{children:[(0,i.jsx)(l,{}),(0,i.jsx)(p,{}),s?(0,i.jsx)(d,{children:s}):null]})}),a=e.div`
  --spinner-size: ${r=>r.$size?r.$size:"96px"};

  display: inline-flex;
  justify-content: center;
  align-items: center;

  @media all and (display-mode: standalone) {
    margin-bottom: 30px;
  }
`,o=e.div`
  position: relative;
  height: var(--spinner-size);
  width: var(--spinner-size);

  opacity: 1;
  animation: fadein 200ms ease;
`,d=e.div`
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  svg,
  img {
    width: calc(var(--spinner-size) * 0.4);
    height: calc(var(--spinner-size) * 0.4);
    border-radius: var(--privy-border-radius-full);
  }
`,l=e.div`
  position: absolute;
  inset: 0;
  width: var(--spinner-size);
  height: var(--spinner-size);

  && {
    border: 4px solid var(--privy-color-border-default);
    border-radius: 50%;
  }
`,p=e.div`
  position: absolute;
  inset: 0;
  width: var(--spinner-size);
  height: var(--spinner-size);
  animation: spin 1200ms linear infinite;

  && {
    border: 4px solid;
    border-color: var(--privy-color-icon-subtle) transparent transparent transparent;
    border-radius: 50%;
  }

  @keyframes spin {
    from {
      transform: rotate(0deg);
    }
    to {
      transform: rotate(360deg);
    }
  }
`;export{v as a};
