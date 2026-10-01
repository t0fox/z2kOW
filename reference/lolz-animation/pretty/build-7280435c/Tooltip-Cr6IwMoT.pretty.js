try{
  let e=typeof window<`u`?window:typeof global<`u`?global:typeof globalThis<`u`?globalThis:typeof self<`u`?self:{
  }
  ,
  t=new e.Error().stack;
  t&&(e._sentryDebugIds=e._sentryDebugIds||{
  }
  ,e._sentryDebugIds[t]=`165fc91a-705d-4217-9695-6a4c25384277`,e._sentryDebugIdIdentifier=`sentry-dbid-165fc91a-705d-4217-9695-6a4c25384277`)
}
catch(e){
}
import{
  __esmMin as e
}
from"./rolldown-runtime-MtAR-uS5.js";
import{
  init___sentry_release_injection_file as t
}
from"./_sentry-release-injection-file-DU9EORvB.js";
import{
  init_xf as n,
  isTouchBrowser as r
}
from"./xenforo-CkeKFsFe.js";
var i,
a=e(()=>{
  t(),i=class{
    constructor(){
      this.handlers=Object.create(null)
    }
    on(e,t){
      var n;return(n=this.handlers)[e]||(n[e]=[]),this.handlers[e].push(t),this
    }
    off(e,t){
      this.handlers[e]&&(this.handlers[e]=this.handlers[e].filter(e=>e!==t))
    }
    emit(e,t){
      if(this.handlers[e])for(let n of this.handlers[e])n.call(this,t)
    }
  }
}
);
function o(e,t){
  let n=new s(t);
  n.trigger(e),
  n.content(r(t));
  function r(e){
    let t=document.createElement(`div`);
    return e.html?t.innerHTML=e.content:t.innerText=e.content,
    t
  }
  return{
    destroy:n.destroy.bind(n),
    update(e){
      var t;
      (t=n.tippy)==null||t.setContent(r(e))
    }
  }
}
var s,
c=e(()=>{
  n(),a(),t(),s=class extends i{
    constructor(e={
    }
){
      super(),this.tippy=null,this.triggerNode=null,this.contentNode=null,this.trigger=this.trigger.bind(this),this.content=this.content.bind(this),this.options=e
    }
    createTippy(){
      !this.triggerNode||this.contentNode===null||this.tippy||(this.tippy=tippy(this.triggerNode,{
        content:this.contentNode,...this.getTippyOptions()
      }
))
    }
    destroy(){
      var e;(e=this.tippy)==null||e.destroy(),this.tippy=null
    }
    trigger(e){
      return this.triggerNode=e,this.createTippy(),{
        destroy:this.destroy.bind(this)
      }
    }
    content(e){
      var t;return(t=e.parentNode)==null||t.removeChild(e),this.contentNode=e,this.createTippy(),{
        destroy:this.destroy.bind(this)
      }
    }
    getTippyOptions(){
      var e,t,n,i,a,o,s;let c={
        popup:{
          arrow:!0,animation:`shift-toward`,theme:`popup`,interactive:!0,zIndex:(e=this.options.zIndex)==null?(t=this.triggerNode)!=null&&t.closest(`.xenOverlay`)?11111:9e3:e,hideOnClick:r||this.options.showOnClick
        }
        ,tooltip:{
          arrow:!0,animation:`shift-toward`,offset:[0,5],zIndex:(n=this.options.zIndex)==null?11111:n
        }
      }
      ;c[`smilie-picker`]={
        ...c.popup,theme:`popup lzt-fe-smilies`,offset:[0,10],delay:[0,100],appendTo:document.body
      }
      ;let l={
        placement:(i=this.options.placement)==null?`top`:i,trigger:r||this.options.showOnClick?`click`:`mouseenter focus`,maxWidth:(a=this.options.maxWidth)==null?250:a,popperOptions:{
          strategy:(o=this.options.placementStrategy)==null?`absolute`:o
        }
        ,onShown:()=>{
          if(document.body.classList.contains(`iOS`)){
            var e;(e=this.triggerNode)==null||e.click()
          }
          this.emit(`shown`,null)
        }
        ,onShow:()=>{
          this.emit(`show`,null)
        }
        ,onHide:()=>{
          this.emit(`hide`,null)
        }
        ,onHidden:()=>{
          this.emit(`hidden`,null)
        }
        ,...c[(s=this.options.style)==null?`tooltip`:s]
      }
      ;return l
    }
    update(){
      var e;(e=this.triggerNode)==null||(e=e.tippy)==null||(e=e.popperInstance)==null||e.update()
    }
  }
}
);
export{
  s as Tooltip,
  c as init_Tooltip,
  o as simpleTooltip
}
;
