declare const mx: { session: { getUserRoleNames(): string[] }, ui: { getContentForm(): { path: string } } };
(async () => {
 const variant: string = "legacy";
 const waitFor = async (check:()=>boolean) => { for(let i=0;i<200;i++){if(check())return;await new Promise(r=>setTimeout(r,50));} throw new Error('Metadata oracle timeout'); };
 const click=async(name:string)=>{
  document.querySelector<HTMLButtonElement>('.mx-name-'+name)!.click();
  await waitFor(()=>document.querySelector('.modal-dialog')!==null);
  const message=document.querySelector('.modal-dialog .modal-body')!.textContent!.trim();
  document.querySelector<HTMLButtonElement>('.modal-dialog button.btn-primary')!.click();
  await waitFor(()=>document.querySelector('.modal-dialog')===null);return message;
 };
 const strict=await click('Strict');if(strict!=='false')throw new Error('Unexpected strict mode');
 const expected={ActiveUserRoles:mx.session.getUserRoleNames()[0]||'',PageName:typeof mx.ui.getContentForm === 'function' ? mx.ui.getContentForm().path : history.state?.pageName || '',EnvironmentURL:window.location.href,Browser:navigator.userAgent,ScreenWidth:String(variant==='viewport'?innerWidth:screen.width),ScreenHeight:String(variant==='viewport'?innerHeight:screen.height)};
 await click('Populate');
 const actual=JSON.parse(localStorage.getItem('mxrb-metadata-oracle')!);
 for(const [key,value] of Object.entries(expected))if(actual[key]!==value)throw new Error('Metadata mismatch: '+key+' '+JSON.stringify(actual[key]));
 Object.defineProperty(screen,'width',{value:0,configurable:true});Object.defineProperty(screen,'height',{value:0,configurable:true});
 Object.defineProperty(window,'innerWidth',{value:0,configurable:true});Object.defineProperty(window,'innerHeight',{value:0,configurable:true});
 await click('Populate');const zero=JSON.parse(localStorage.getItem('mxrb-metadata-oracle')!);
 const expectedZeroWidth=variant==='legacy'?actual.ScreenWidth:variant==='viewport'?null:'0';
 const expectedZeroHeight=variant==='legacy'?actual.ScreenHeight:variant==='viewport'?null:'0';
 if(screen.width!==0 || screen.height!==0 || zero.ScreenWidth!==expectedZeroWidth || zero.ScreenHeight!==expectedZeroHeight)throw new Error('Unexpected zero-dimension behavior: '+JSON.stringify(zero));
 return {status:'passed',variant,strict,page_path:actual.PageName,history_page:history.state?.pageName,role:actual.ActiveUserRoles,browser_matches:true,url_matches:true,screen_matches:true,zero_dimensions_verified:true,zero_width:zero.ScreenWidth,zero_height:zero.ScreenHeight};
})();
