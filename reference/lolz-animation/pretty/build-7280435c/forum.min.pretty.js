try{
  let e=typeof window<`u`?window:typeof global<`u`?global:typeof globalThis<`u`?globalThis:typeof self<`u`?self:{
  }
  ,
  t=new e.Error().stack;
  t&&(e._sentryDebugIds=e._sentryDebugIds||{
  }
  ,e._sentryDebugIds[t]=`a3bd28db-dd3b-4b6c-9521-faf007ae7f1e`,e._sentryDebugIdIdentifier=`sentry-dbid-a3bd28db-dd3b-4b6c-9521-faf007ae7f1e`)
}
catch(e){
}
import{
  __esmMin as e
}
from"../assets/js/chunks/rolldown-runtime-MtAR-uS5.js";
import{
  init_jquery_xenforo_rollup as t,
  jquery_xenforo_rollup_default as n
}
from"../assets/js/chunks/jquery-Csqho11y.js";
import{
  init___sentry_release_injection_file as r
}
from"../assets/js/chunks/_sentry-release-injection-file-DU9EORvB.js";
import{
  copyToClipboard as i,
  init_xenforo as a,
  init_xf as o,
  phrase as s,
  xenforo_default as c
}
from"../assets/js/chunks/xenforo-CkeKFsFe.js";
import{
  init_index_client$2 as l,
  mount as u,
  unmount as d
}
from"../assets/js/chunks/svelte-src-DujwBjvd.js";
import{
  init_sortable_esm as f,
  sortable_esm_default as p
}
from"../assets/js/chunks/sortablejs-modular-B2JIdjR3.js";
import{
  init_mount as m,
  mountDateRangePicker as h
}
from"../assets/js/chunks/mount-DBDdWZ1K.js";
import{
  init_moment as g,
  moment_default as _
}
from"../assets/js/chunks/moment-RSjls90c.js";
import{
  PopupMenu as v,
  init_PopupMenu as y
}
from"../assets/js/chunks/PopupMenu-Bzk6pNTB.js";
function b(e){
  n(`<link />`).attr(`rel`,`next`).attr(`href`,e).appendTo(document.head)
}
function x(e){
  var t=n(`link[rel="next"]`);
  t.length?t.attr(`href`,e):b(e)
}
function S(){
  n(`link[rel="next"]`).remove()
}
function C(){
  return n(`link[rel="next"]`).attr(`href`)
}
function w(){
  let e=n(`.NodeList.forums .ForumSearch-noResults`);
  return e.length||(e=n(`<div class="ForumSearch-noResults muted"/>`).text(s(`no_results_found`)).hide().appendTo(`.NodeList.forums`)),
  e
}
function T(){
  return document.documentElement.classList.contains(`userStyle--51`)
}
function E(e){
  var t;
  let n=(t=e.get(0))==null?void 0:t.parentElement;
  for(;n&&n!==document.body&&n!==document.documentElement;){
    let e=getComputedStyle(n).overflowY;
    if((e===`auto`||e===`scroll`)&&n.scrollHeight>n.clientHeight)return n;
    n=n.parentElement
  }
  return document.scrollingElement||document.documentElement
}
function D(e){
  let t=E(e);
  if(!t)return;
  t.style.setProperty(`overflow`,`hidden`,`important`);
  let n=!1,
  r=t===document.scrollingElement||t===document.documentElement||t===document.body,
  i=(getComputedStyle(t).getPropertyValue(`scrollbar-gutter`)||``).includes(`stable`);
  if(r&&!i){
    let e=window.innerWidth-document.documentElement.clientWidth;
    e>0&&(t.style.setProperty(`padding-right`,e+`px`,`important`),n=!0)
  }
  V={
    el:t,
    padded:n
  }
}
function O(){
  V&&(V.el.style.removeProperty(`overflow`),V.padded&&V.el.style.removeProperty(`padding-right`),V=null)
}
function k(){
  z&&(d(z,{
    outro:!0
  }
),z=null,B==null||B.removeClass(`PopupMenuTarget`),B=null,O())
}
function A(e){
  let t=e.find(`.nodeTitle > a[href]`).first();
  if(!t.length)return null;
  let n=t.attr(`href`);
  if(!n)return null;
  let r=(e.attr(`class`)||``).match(/\bnode(\d+)\b/);
  if(!r)return null;
  let i=(e.find(`.forumTitle`).first().text()||t.text()||``).trim();
  return{
    id:r[1],
    href:n,
    title:i
  }
}
function j(e,t){
  if(!T())return;
  let r=A(t);
  if(!r)return;
  e.preventDefault(),
  k();
  function a(){
    c.redirect(c.canonicalizeUrl(r.href.replace(/\/$/,``)+`/create-thread`))
  }
  function o(){
    i(c.canonicalizeUrl(r.href)),
    c.alert(s(`im_action_url_in_node_copied`),``,3e3,null,`success`)
  }
  function l(){
    window.open(c.canonicalizeUrl(r.href),`_blank`)
  }
  function d(){
    I={
      id:r.id,
      title:r.title,
      ts:Date.now()
    }
    ;
    let e=n(`<a>`,{
      href:c.canonicalizeUrl(`feed/create-tab`),"data-overlaycache":`false`
    }
);
    e.one(`OverlayAjaxError`,function(){
      I=null
    }
),
    new c.OverlayTrigger(e),
    e.trigger(`click`)
  }
  let f=[{
    icon:`fa fa-plus`,label:s(`create_thread`),callback:a
  }
  ,{
    icon:`fa fa-link`,label:s(`im_action_copy_link_in_node`),callback:o
  }
  ,{
    icon:`fa fa-external-link-alt`,label:s(`open_link_in_new_tab`),callback:l
  }
  ,{
    icon:`fa fa-folder-plus`,label:s(`create_tab`),callback:d
  }
],
  p=e.type===`touchstart`,
  m=p?e.targetTouches[0].clientX:e.clientX,
  h=p?e.targetTouches[0].clientY:e.clientY;
  z=u(v,{
    target:document.body,props:{
      items:f,target:t.get(0),unmountMenu:k,clientX:m,clientY:h
    }
  }
),
  B=t.addClass(`PopupMenuTarget`),
  D(t)
}
function M(){
  H&&(clearTimeout(H),H=null),
  U=null
}
function N(e,t){
  return n(e.target).closest(R)[0]===t
}
var P,
F,
I,
L,
R,
z,
B,
V,
H,
U,
W,
G,
K=e(()=>{
  t(),a(),o(),f(),l(),m(),g(),y(),r(),P=()=>n(window).width()<=1024,F=function(){
    let e=n(`.discussionListItem .InlineModCheck:not(.labelautyActivated)`);n.fn.labelauty&&!P()?e.labelauty({
      label:!1
    }
):e.removeClass(`labelauty`).show(),e.addClass(`labelautyActivated`)
  }
  ,c.ForumList=function(e){
    this.__construct(e)
  }
  ,c.ForumList.prototype={
    __construct:function(e){
      if(e.closest(`.sidebar`).is(`:hidden`)){
        n(window).on(`resize`,()=>{
          e.closest(`.sidebar`).is(`:hidden`)||(e.data(`XenForo.ForumList`,null),c.create(`XenForo.ForumList`,e)),F()
        }
);return
      }
      if(e.closest(`.sidebar`).data(`enabled`)){
        console.log(`already enabled`);return
      }
      e.closest(`.sidebar`).data(`enabled`,1),this.$nodeList=e,this.$node=n(`body`).attr(`class`)?n(`.node.`+n(`body`).attr(`class`)):void 0,this.nodeHref=void 0;var t=this;this.$destination=n(`.mainContent`),this.navigationCache={
      }
      ,this.xhr=null,this.searchQueryString=null,this.searchQuery=``,this.checkHistorySupport(),this.updateThreads(),this.$nodeList.find(`ol`).not(`.nodeList, .subForumList`).css({
        overflow:`hidden`,marginBottom:`-8px`
      }
),e.on(`click`,`a`,function(e){
        e.preventDefault(),t.clickEvent(n(this),!1)
      }
),e.on(`click`,`.ExpandSubForumList`,function(){
        let e=n(this).closest(`.node`).find(`ol, .subForumList`).first();e.is(`:visible`)?(e.xfSlideUp(300,function(){
          n(this).removeClass(`current`)
        }
),n(this).removeClass(`expanded`)):(e.xfSlideDown(300,function(){
          n(this).addClass(`current`)
        }
),n(this).addClass(`expanded`))
      }
),this.$node&&(this.$node.hasClass(`current`)||this.$node.addClass(`current`),this.$node.parents(`.node:not(.category)`).each(function(){
        n(this).addClass(`current`)
      }
));let r=n(`.list.node.current`);r.length>0&&r.find(`> .nodeInfo > .nodeText > .nodeTitle > .ExpandSubForumList`).addClass(`expanded`),n(`.subForumList .current > div > .nodeTitle > .ExpandSubForumList`).addClass(`expanded`),this.createNavigationCache(),this.bindPageNav(),e.on(`BindPageNav`,()=>{
        this.bindPageNav()
      }
),this.onFirstPageLoad();let i=n(`.discussionListMainPage`);i.length&&n.setCookie(`discussion_list_size`,i.width(),new Date(new Date().setFullYear(new Date().getFullYear()+1)))
    }
    ,onFirstPageLoad:function(){
      let e=location.pathname.slice(1),t=this.$nodeList.find(`a[href="${e}"]`);t.length&&this.clickEvent(t,!0)
    }
    ,clickEvent:function(e,t){
      if(e.hasClass(`OverlayTrigger`))return;let r=e.attr(`href`);if(this.$node=e,this.nodeHref=r,e.closest(`.nodeTitle`).find(`span.ExpandSubForumList`).length&&e.closest(`.nodeTitle`).find(`span.ExpandSubForumList`).hasClass(`expanded`))e.closest(`.node`).find(`ol`).each(function(){
        e.closest(`.node`).is(`.current`)&&e.stop(!0).css(`display`,`block`)
      }
),e.closest(`.node`).find(`.current`).removeClass(`current`),r.indexOf(`link-forums/`)<0?this.nodeClick(e,t):e.closest(`.node`).hasClass(`noLoad`)||(window.location.href=r);else{
        this.$nodeList.find(`.node.current`).removeClass(`current`),this.$nodeList.find(`.expanded`).removeClass(`expanded`);let i=this.$nodeList.find(`.node ol.current`);for(let t=0;t<i.length;t++){
          let r=n(i[t]),a=e.closest(`.node ol`);!r.is(a)&&!r.is(a.parents())&&!r.is(a.parents(`.node`))&&r.xfSlideUp(300,function(){
            n(this).removeClass(`current`).css(`display`,``)
          }
)
        }
        r.indexOf(`link-forums/`)<0?this.nodeClick(e,t):e.closest(`.node`).hasClass(`noLoad`)||(window.location.href=r);let a=n(`.list.node.current`);a.length>0&&a.find(`> .nodeInfo > .nodeText > .nodeTitle > .ExpandSubForumList`).addClass(`expanded`),this.$nodeList.find(`.subForumList .current > .unread .ExpandSubForumList`).addClass(`expanded`)
      }
    }
    ,nodeClick:function(e,t){
      let r=e.closest(`.node`),i=e.attr(`href`);this.$nodeList.find(`.node.current`).removeClass(`current`),this.$nodeList.find(`.expanded`).removeClass(`expanded`);let a=this.$nodeList.find(`.node ol.current`);for(let t=0;t<a.length;t++){
        let r=n(a[t]),i=e.closest(`.node ol`);!r.is(i)&&!r.is(i.parents())&&!r.is(i.parents(`.node`))&&r.xfSlideUp(300,function(){
          n(this).removeClass(`current`).css(`display`,``)
        }
)
      }
      if(r.find(`ol`).first().xfSlideDown(300,function(){
        n(this).addClass(`current`).css(`display`,`block`)
      }
),e.parents(`.node:not(.category)`).each(function(){
        n(this).addClass(`current`)
      }
),r.find(`.ExpandSubForumList`).first().addClass(`expanded`),!(t||r.hasClass(`noLoad`))){
        if(location.pathname.slice(1)!==i){
          let e=n(`.bg_img`);e.stop().css(`opacity`,0),this.onPageLoadedCallback=function(){
            if(c.isTouchBrowser()){
              let e=n(`#NodeListSection`);if(!e.hasClass(`hidden`)){
                e.xfSlideUp(300,()=>{
                  e.addClass(`hidden`)
                }
);let t=n(`#NodeListToggle`);t.text(t.data(`show`))
              }
            }
            let t;this.backgroundImageLoader&&(this.backgroundImageLoader.src=``,this.backgroundImageLoader=void 0);let r=e.css(`background-image`);if(r===`none`?r=void 0:r&&(r=r.slice(5,-2)),r){
              let e=new Image;e.src=r,t=e.complete?Promise.resolve():new Promise((t,n)=>{
                e.addEventListener(`load`,t),e.addEventListener(`error`,n)
              }
),this.backgroundImageLoader=e
            }
            let i=async()=>{
              if(!t){
                e.css(`opacity`,1);return
              }
              try{
                await t
              }
              catch(e){
                return
              }
              e.delay(10).animate({
                opacity:1
              }
              ,c.speed.normal)
            }
            ;if(!window.scrollY){
              i();return
            }
            let a=()=>{
              window.scrollY||(window.removeEventListener(`scroll`,a),i())
            }
            ,o=()=>{
              window.removeEventListener(`scroll`,a),window.removeEventListener(`scrollend`,o),i()
            }
            ;window.addEventListener(`scroll`,a,{
              passive:!0
            }
),window.addEventListener(`scrollend`,o,{
              passive:!0
            }
),window.scrollTo({
              top:0,behavior:`smooth`
            }
)
          }
        }
        this.loadNodePage(i)
      }
    }
    ,updateBreadcrumb:function(e){
      let t=n(`.breadBoxTop .pageWidth`);if(!e.breadcrumb){
        t.find(`fieldset.breadcrumb`).remove();return
      }
      t.html(e.breadcrumb),t.find(`fieldset.breadcrumb:visible`).length||t.xfSlideIn(),t.xfActivate()
    }
    ,deleteStartSlash:function(e){
      return e[0]===`/`&&e.length>1?e.substr(1):e
    }
    ,createNavigationCache:function(){
      let e=this.$destination.clone();e.find(`.chosen-container`).remove(),history.replaceState({
        html:e.html(),next:C(),bodyClasses:n(`body`).attr(`class`),contentClasses:n(`#content`).attr(`class`),breadcrumb:n(`.breadBoxTop .pageWidth`).html(),createThreadButton:n(`a.CreateThreadButton`).closest(`.section`).html()
      }
      ,location.pathname.replace(/^\//,``)+location.search)
    }
    ,setStateHandler:function(){
      n(window).on(`popstate`,function(e){
        if(c.preservePopstate||/^((?!chrome|android).)*safari/i.test(navigator.userAgent))return;e=e.originalEvent;let t=this.$destination.find(`.InlineModForm`).data(`rawOverlay`);this.$destination.html(e.state.html),e.state.next?x(e.state.next):S(),this.updateBreadcrumb({
          breadcrumb:e.state.breadcrumb
        }
),e.state.createThreadButton&&n(`a.CreateThreadButton`).closest(`.section`).html(e.state.createThreadButton).xfActivate(),e.state.bodyClasses&&n(`body`).attr(`class`,e.state.bodyClasses),e.state.contentClasses&&n(`#content`).attr(`class`,e.state.contentClasses),n(`.SearchInputQuery`).val(new URLSearchParams(location.search).get(`title`)),n(`#InlineModOverlay, .SelectionCount.cloned`).remove(),n(t).appendTo(`.InlineMod.SelectionCountContainer`),this.$destination.xfShow(c.speed.normal,function(){
          this.$destination.xfActivate(),this.bindPageNav(),this.$nodeList.find(`.node.current`).removeClass(`current`);let e=this.$nodeList.find(`a[href$="${this.deleteStartSlash((window.location.pathname===`/`?`/forums/`:window.location.pathname)+window.location.search)}"]`).closest(`.node`).addClass(`current`),t=e.closest(`ol`);for(;t.length;)t.css(`display`,`block`),t=t.parent().closest(`ol`);for(t=e.parent().closest(`.node:not(.level_1)`);t.length;)t.addClass(`current`),t=t.parent().closest(`.node:not(.level_1)`)
        }
        .bind(this)),n(`#content select:not(#ModerationSelect)`).each(function(){
          c.create(`XenForo.PrettySelect`,n(this))
        }
)
      }
      .bind(this))
    }
    ,setPageUrl:function(e){
      history.pushState({
        page:e,type:`page`,contentClass:n(`#content`).attr(`class`)
      }
      ,document.title,e)
    }
    ,checkHistorySupport:function(){
      history.pushState&&this.setStateHandler()
    }
    ,updateThreads:function(){
      n(`.DiscussionList`).on(`UpdateSearchResults`,function(){
        this.createNavigationCache()
      }
      .bind(this)),this.createNavigationCache()
    }
    ,loadNodePage:function(e=!1){
      let t=e;this.xhr&&this.xhr.abort(),this.xhr=c.ajax(t,{
        from_sidebar:!0
      }
      ,n.context(this,`loadNodePageCallback`))
    }
    ,changeCreateThreadLink:function(e){
      e.createThreadLink||(e.createThreadLink=``),n(`.CreateThreadButton`).attr(`href`,e.createThreadLink).removeClass(`hidden`),n(`.NoPermissionToCreateThread`).addClass(`hidden`)
    }
    ,hideCreateThreadButton:function(e){
      n(`.CreateThreadButton`).addClass(`hidden`),n(`.NoPermissionToCreateThread`).text(e.cannotPostThreadError).removeClass(`hidden`)
    }
    ,removeTooltips:function(){
      n(`.tippy-popper`).remove()
    }
    ,loadNodePageCallback:function(e){
      if(c.hasResponseError(e)){
        this.xhr=null;return
      }
      let t;if(n(`.titleBar`).length&&(t=n(`.titleBar`).get(0).outerHTML),e._redirectTarget){
        window.location=e._redirectTarget;return
      }
      if(n(`#InlineModOverlay`).remove(),this.createNavigationCache(),this.setPageUrl(this.nodeHref),this.removeTooltips(),this.$destination.hide(),P()){
        let t=n(`.sidebar`)[0].outerHTML,r=n(`<div></div>`).html(e.templateHtml),i=r.find(`.sidebar`),a=!!i.length;i.remove();let o=r.find(`.titleBar`);if(o.length){
          let e=o.get(0).outerHTML;o.remove(),this.$destination.html((a?e+t:t+e)+r.html())
        }
        else this.$destination.html(t+r.html())
      }
      else this.$destination.html(e.templateHtml);if(this.inlineModFormHtml=n(e.templateHtml).find(`#InlineModControls`).prop(`outerHTML`),this.removeTooltips(),e.nextPageHref?x(e.nextPageHref):S(),e.notices)n(`.FloatingContainer.Notices, .BottomNotices`).remove(),this.$destination.prepend(n(e.notices));else if(P()){
        let e=this.$destination.find(`.Notice`);if(e.length){
          let t=e.toArray().map(e=>e.outerHTML).reverse();e.remove();for(let e of t)this.$destination.prepend(n(e))
        }
      }
      var r=this;new c.ExtLoader(e,function(){
        n(`#content`).removeAttr(`class`).attr(`class`,e.templateName),e.node_id?n(`body`).attr(`class`,`node`+e.node_id):e.tabLink?n(`body`).attr(`class`,e.tabLink):n(`body`).attr(`class`,`index`),r.$destination.xfShow(0,function(){
          n(`#content select:not(#ModerationSelect)`).each(function(){
            c.create(`XenForo.PrettySelect`,n(this))
          }
)
        }
),t&&!n(`.titleBar`).length&&e.h1&&r.$destination.prepend(n(t)),r.bindPageNav(),r.$destination.xfActivate(),n(`title`).text(e.title),e.canPostThread?r.changeCreateThreadLink(e):r.hideCreateThreadButton(e),r.xhr=null,F(),r.updateBreadcrumb(e),r.createNavigationCache(),r.onPageLoadedCallback&&(r.onPageLoadedCallback(),r.onPageLoadedCallback=void 0)
      }
),this.updateThreads()
    }
    ,bindPageNav:function(){
      n(`.PageNav`).off(`seek`).on(`seek`,function(){
        this.bindPageNav()
      }
      .bind(this)),n(`.PageNav`).find(`a[href]`).off(`click`).on(`click`,function(e){
        e.preventDefault(),this.createNavigationCache(),this.nodeHref=n(e.target).attr(`href`),c.ajax(this.nodeHref,{
        }
        ,n.context(this,`loadNodePageCallback`))
      }
      .bind(this))
    }
  }
  ,isScrolledIntoView=function(e){
    var t=n(window).scrollTop()+n(`#header`).height(),r=t+n(window).height(),i=n(e).offset().top,a=i+n(e).height();return a<=r&&i>=t
  }
  ,c.LiveForumPages=function(e){
    this.__construct(e)
  }
  ,c.LiveForumPages.prototype={
    __construct:function(e){
      this.$discussionList=e,this.$destination=n(`._insertLoadedContent`),this.$defaultThreadsHtml=this.$destination.html(),this.$defaultPageNavHtml=n(`.PageNav`).length?n(`.PageNav`).get(0).outerHTML:``,this.$options=n(`.DiscussionListOptions`),this.$options.find(`select`).each(function(){
        let e=n(this).data(`default-value`)||``,t=n(this).find(`:selected`).val()||``;e!==t&&n(this).data(`default-value`,t)
      }
),this.href=this.$options.attr(`action`),this.timeout=3e3,this.timer=void 0,this.initThreadFilter(),this.initThreadSearch(),this.initInfinityScroll(),this.replaceResultsFound(this.$defaultThreadsHtml);let t=new URLSearchParams(window.location.search);t.has(`online_authors`)&&t.get(`online_authors`)===`on`&&n(`#ctrl_online_authors`).prop(`checked`,!0),t.has(`my_threads`)&&t.get(`my_threads`)===`on`&&n(`#ctrl_my_threads`).prop(`checked`,!0),n(`.node`).on(`click`,function(e){
        n(e.target).hasClass(`ExpandSubForumList`)||this.destroyInfinityScroll()
      }
      .bind(this)),this.$discussionList.on(`LoadPageWithoutCache`,function(){
        this.searchThreads(!0,!0)
      }
      .bind(this));let r=n(`.UpdateFeedButton`);r.on(`click`,()=>{
        this.searchThreads(!0),r[0]._tippy.hide()
      }
)
    }
    ,initInfinityScroll:function(){
      let e=``;this.destroyInfinityScroll(),this.viewMoreButton=`.ForumViewMoreButton`;var t={
        path:function(){
          let e=C();if(e){
            e[0]!==`/`&&e[0]!==`h`&&(e=`/`+e);let r=e.indexOf(`?`)>0?`&`:`?`;var t=e+r+`next_page_loading=1&_xfResponseType=json&_xfToken=`+c._csrfToken;return n(`.stickyThreads`).is(`:visible`)||(t+=`&_threadFilter=1`),t
          }
        }
        ,fetchOptions:{
          headers:{
            "x-requested-with":`XMLHttpRequest`
          }
        }
        ,responseBody:`json`,append:!1,history:!1,scrollThreshold:800
      }
      ;let r=n(`.PageNav`),i=n(`.NoResultsFound`).hasClass(`hidden`),a=P();if(a&&i&&(!r.length||r.data(`page`)!==r.data(`last`))?(t.button=this.viewMoreButton,n(t.button).css(`display`,`block`)):a&&(t.button=this.viewMoreButton,n(t.button).css(`display`,`none`)),a||!i)t.scrollThreshold=!1;else{
        let e=this.$discussionList.find(`.discussionListItem`).toArray(),r=e.length&&e.every(e=>n(e).hasClass(`ignored`));r&&(t.loadOnScroll=!1)
      }
      this.$discussionList.infiniteScroll(t),this.$discussionList.on(`load.infiniteScroll`,function(t,r){
        if(!c.hasResponseError(r)){
          if(!r.templateHtml)return n(`.AllResultsShowing`).removeClass(`hidden`),this.$discussionList.data(`infiniteScroll`)&&this.$discussionList.infiniteScroll(`destroy`),n(this.viewMoreButton).hide();this.replacePageNav(r.pageNav),r.nextPageHref&&e!==r.templateHtml?(x(r.nextPageHref),e=r.templateHtml):(S(r.nextPageHref),this.destroyInfinityScroll()),this.allResultsShowing(r.nextPageHref),this.insertContent(r)
        }
      }
      .bind(this))
    }
    ,destroyInfinityScroll:function(e){
      e&&n(`.AllResultsShowing`).removeClass(`hidden`),this.$discussionList.data(`infiniteScroll`)&&(this.$discussionList.off(`load.infiniteScroll`),this.$discussionList.infiniteScroll(`destroy`)),n(this.viewMoreButton).hide()
    }
    ,scheduleSearch:function(e){
      this.timer&&clearTimeout(this.timer);let t=this;this.timer=setTimeout(function(){
        t.searchThreads()
      }
      ,e===void 0?400:e)
    }
    ,initThreadFilter:function(){
      this.$options.find(`select,input`).on(`change`,function(){
        this.scheduleSearch(300)
      }
      .bind(this))
    }
    ,searchThreads:function(e,t){
      var r=e||this.searchOrShowDefaultThreads();let i=this.$options.serializeArray();if(i.push({
        name:`_threadFilter`,value:1
      }
),this.$threadSearchInput.length>0&&this.$threadSearchInput.val().length>=2&&i.push({
        name:`q`,value:this.$threadSearchInput.val()
      }
),t===!0){
        let e=new URLSearchParams(window.location.search),t=n(`select[name="node_id[]"]`);t.find(`option[selected="selected"]`).removeAttr(`selected`);for(let[n,r]of Array.from(e.entries()).filter(e=>e[0]===`node_id[]`))t.find(`option[value="${r}"]`).attr(`selected`,`selected`);t.trigger(`chosen:updated`)
      }
      let a=new URLSearchParams,o=[`_xfToken`,`_threadFilter`,`q`],s=new URLSearchParams(window.location.search);s.has(`tab`)&&a.append(`tab`,s.get(`tab`));let l=[],u=[],d=[];for(let e of i)e.name===`prefix_id[]`?l.push(e.value):e.name===`node_id[]`?u.push(e.value):e.name===`prefix_id_and[]`?d.push(e.value):o.includes(e.name)||(e.name.endsWith(`[]`)||!a.has(e.name))&&e.value.length>0&&a.append(e.name,e.value);for(let e of l)a.append(`prefix_id[]`,e);for(let e of u)a.append(`node_id[]`,e);for(let e of d)a.append(`prefix_id_and[]`,e);if(window.history.pushState({
      }
      ,null,decodeURI(`${window.location.origin}${window.location.pathname}?${a.toString()}`).replace(/%2C7/g,`,`)),this.$threadSearchInput.val()&&!this.isSearched&&!r&&t!==!0){
        this.replaceResultsFound(this.$defaultThreadsHtml),this.replacePageNav(this.$defaultPageNavHtml),n(`.stickyThreads`).show(),this.$destination.html(this.$defaultThreadsHtml).xfActivate(),this.isSearched=!0,this.searchQueryString=null,this.searchQuery=``;return
      }
      let f=i.filter(e=>e.name===`q`)[0]||!1;if(f&&f.value===this.searchQuery&&a.toString()===this.searchQueryString)return;this.searchQueryString=a.toString(),this.searchQuery=f.value,this.showSearchMask();let p=this.$options.attr(`action`);if(p){
        let e=this._searchSeq=(this._searchSeq||0)+1;c.ajax(p,i,t=>{
          e===this._searchSeq&&this.threadSearchCallback(t)
        }
)
      }
      else location.reload()
    }
    ,threadSearchCallback:function(e){
      this.timer&&clearTimeout(this.timer),this.$sticky=n(`.stickyThreads`),n(`._insertLoadedContent`).length||(this.$destination=n(`<div class="latestThreads _insertLoadedContent">`).appendTo(n(`.discussionListItems`))),this.$sticky.length||(this.$sticky=n(`<div class="stickyThreads">`).appendTo(n(`.discussionListItems`))),!c.hasResponseError(e)&&(this.destroyInfinityScroll(),e.nextPageHref?x(e.nextPageHref):(S(e.nextPageHref),this.destroyInfinityScroll()),this.replacePageNav(e.pageNav),this.replaceResultsFound(e.templateHtml),this.$destination.html(e.templateHtml).xfActivate(),e.stickyThreadsTemplateHtml?(this.$sticky.xfShow(),this.$sticky.html(e.stickyThreadsTemplateHtml).xfActivate()):this.$sticky.xfHide(),F(),this.hideSearchMask(),e.nextPageHref?(n(`.AllResultsShowing`).addClass(`hidden`),n(`.NoResultsFound`).addClass(`hidden`),this.$discussionList.data(`totalthreads`,n(e.templateHtml).find(`div.discussionListItem--Wrapper`).length),this.initInfinityScroll()):e.templateHtml&&(n(`.AllResultsShowing`).removeClass(`hidden`),!n(`.latestThreads`).children().length&&n(`.stickyThreads`).children().length?n(`.AllResultsShowing`).detach().insertAfter(`.stickyThreads`):n(`.AllResultsShowing`).detach().insertAfter(`.latestThreads`)),n(`.DiscussionList`).trigger(`UpdateSearchResults`))
    }
    ,searchOrShowDefaultThreads:function(){
      var e=!1;return this.$options.find(`select`).each(function(){
        let t=n(this).data(`default-value`)||``,r=n(this).find(`:selected`).val()||``;if(t!==r)return e=!0,!1
      }
),!e&&this.$threadSearchInput.val()&&(e=this.$threadSearchInput.val().length>=3),e||(e=!!n(`#ctrl_online_authors`).prop(`checked`)),e||(e=!!n(`#ctrl_my_threads`).prop(`checked`)),e||(e=!this.searchQuery),e||(this.isSearched=!1),e
    }
    ,initThreadSearch:function(){
      this.$threadSearchInput=this.$options.find(`.SearchInputQuery`),this.isSearched=!1,this.$button=n(`<i class="inputRelativeIcon fas fa-times"/>`).appendTo(this.$threadSearchInput.parent()).hide(),this.$threadSearchInput.length&&(this.$threadSearchInput.val().trim()?this.$button.show():this.$button.hide()),n(`.discussionListItem`).length||n(`.AllResultsShowing`).removeClass(`hidden`),this.$button.on(`click`,function(){
        this.$threadSearchInput.val(``),this.searchThreads(!0),this.$button.hide()
      }
      .bind(this)),this.$threadSearchInput.on(`change keyup paste`,function(){
        this.$threadSearchInput.val().trim()?this.$button.show():this.$button.hide(),this.scheduleSearch(400)
      }
      .bind(this))
    }
    ,replacePageNav:function(e){
      if(!e||e.length<1)n(`.PageNav`).empty();else{
        let t=n(`.PageNav`).length;t?n(`.PageNav`).replaceWith(e):n(e).appendTo(n(`.pageNavLinkGroup`)),n(`.pageNavLinkGroup`).xfActivate(),this.$destination.xfActivate(),n(`.NodeList.forums`).trigger(`BindPageNav`)
      }
    }
    ,insertContent:function(e){
      let t=n(e.templateHtml);c.IgnoredContentDisplayed&&t.filter(`.ignored`).removeClass(`ignored`),t.clone().each(function(){
        n(`#`+n(this).attr(`id`)).length&&t.closest(`#`+n(this).attr(`id`)).html(``)
      }
),t.xfInsert(`appendTo`,this.$destination,`fadeIn`,100,function(){
        setTimeout(function(){
          this.inProgress=!1
        }
        .bind(this),300)
      }
      .bind(this)),F()
    }
    ,replaceResultsFound:function(e){
      e?n(`.NoResultsFound`).hasClass(`hidden`)||n(`.NoResultsFound`).addClass(`hidden`):(n(`.NoResultsFound`).hasClass(`hidden`)&&n(`.NoResultsFound`).removeClass(`hidden`),n(`.AllResultsShowing`).hasClass(`hidden`)||n(`.AllResultsShowing`).addClass(`hidden`),this.destroyInfinityScroll())
    }
    ,showSearchMask:function(){
      n(`.forumImprovements--mask`).removeClass(`hidden`)
    }
    ,hideSearchMask:function(){
      n(`.forumImprovements--mask`).addClass(`hidden`)
    }
    ,allResultsShowing:function(e){
      e===!1&&n(`.AllResultsShowing`).removeClass(`hidden`)
    }
  }
  ,I=null,c.CreateTabForm=function(e){
    var t=e.find(`.TabTitleInput`),r=50,i=e.find(`.TabLink`).val();let a=e.find(`select.selectForums`),o=e.find(`select.selectPrefixes`),s={
      width:`100%`,search_contains:!0,inherit_select_classes:!0,enable_split_word_search:!0,disable_search:c.isPositive(a.data(`search`))?0:1,max_selected_options:50
    }
    ;a.chosen(s),a.trigger(`chosen:updated`),o.chosen(s),o.trigger(`chosen:updated`),e.on(`AutoValidationComplete`,function(t){
      if(t.preventDefault(t),t.ajaxData.tabDeleted){
        let e=n(`.PersonalTabs`).find(`.personalTab`+i);e.hasClass(`current`)&&n(`.NodeList.forums .node0 a`).trigger(`click`),e.xfRemove(`xfSlideUp`)
      }
      else t.ajaxData.templateHtml&&(t.ajaxData.tabUpdated?n(t.ajaxData.templateHtml).xfInsert(`replaceAll`,n(`.PersonalTabs`).find(`.personalTab`+i)):n(t.ajaxData.templateHtml).xfInsert(`appendTo`,n(`.PersonalTabs`)));var r=e.parents(`.xenOverlay`).data(`overlay`);r?setTimeout(function(){
        r.close()
      }
      ,0):window.location.href=`/`
    }
);function l(e,t){
      let n=e.join(`, `);return t&&t.length>0&&(n+=` (`+t.join(`, `)+`)`),n.substr(0,r)
    }
    let u={
      title:t.val().trim(),forums:l(d(),f())
    }
    ;function d(){
      return a.find(`:selected`).map(function(){
        return n(this).text().trim()
      }
).get()
    }
    function f(){
      return o.find(`:selected`).map(function(){
        return n(this).text().trim()
      }
).get()
    }
    function p(){
      let e=l(d(),f());(t.val()===``||u.title===u.forums)&&t.val(e)
    }
    if(a.on(`change`,p),o.on(`change`,p),t.on(`input`,function(){
      u.title=t.val().trim()
    }
),t.val()===``&&p(),I){
      let e=I;if(I=null,Date.now()-e.ts<1e4){
        let t=a.find(`option[value="`+e.id+`"]`);!t.length&&e.title&&(t=a.find(`option`).filter(function(){
          return n(this).text().trim()===e.title
        }
)),t.length&&a.val(t.first().attr(`value`)).trigger(`chosen:updated`).trigger(`change`)
      }
    }
    let m,h,g,_;e.on(`AutoValidationBeforeSubmit`,function(){
      g=new URLSearchParams(location.search),m=e.find(`input[name="tabLink"]`).val(),h=g.get(`tab`)
    }
),e.on(`AutoValidationComplete`,function(e){
      _=e.ajaxData.link,_&&m===h&&(g.set(`tab`,_),location.search=g.toString())
    }
),c.PrettySelect(e.find(`select.Chosen`))
  }
  ,c.CreatePersonalExtendedTab=function(e){
    let t=new c.OverlayLoader(e,!1,{
    }
);e.on(`click`,function(r){
      r.preventDefault();let i=e.attr(`href`),a=e.closest(`form`),o=a.serializeArray();return o.push({
        name:`isExtendedTab`,value:`1`
      }
),c.ajax(i,o,n.context(t,`loadSuccess`),{
        type:`GET`
      }
),!1
    }
)
  }
  ,c.ExcludeForumsForm=function(e){
    let t=e.find(`select`),n={
      width:`100%`,search_contains:!0,inherit_select_classes:!0,enable_split_word_search:!0,disable_search:c.isPositive(t.data(`search`))?0:1,max_selected_options:1/0
    }
    ;t.chosen(n),t.trigger(`chosen:updated`)
  }
  ,c.CreateThreadButton=function(e){
    e.on(`click`,function(t){
      var r;if(t.preventDefault(),((r=e.attr(`href`))==null?void 0:r.length)>0){
        c.redirect(e.attr(`href`));return
      }
      let i=new c.OverlayLoader(n(`<a />`).attr(`href`,e.data(`createThread`)),!0,{
        className:`selectForumOverlay`
      }
);i.show()
    }
)
  }
  ,c.NodeListToggle=function(e){
    var t=n(`#NodeListSection`);e.on(`click`,function(){
      if(!n(`.NodeList.forums`).data(`XenForo.ForumList`).xhr)if(t.is(`:hidden`)){
        let n=window.location.hash;if(/^#\d+$/.test(n)){
          let e=window.location.href.replace(window.location.origin,``);history.replaceState(null,``,e.replace(window.location.hash,``))
        }
        t.xfSlideDown(300),e.text(e.data(`hide`))
      }
      else t.xfSlideUp(300),e.text(e.data(`show`))
    }
)
  }
  ,c.HideThread=function(e){
    var t=function(t){
      if(!c.hasResponseError(t)){
        var r;(r=e.get(0)._tippy)==null||r.hide(),n(`#thread-`+e.data(`tid`)).xfSlideUp()
      }
    }
    ;e.on(`click`,function(n){
      n.preventDefault(),c.ajax(e.attr(`href`),{
        thread_id:e.data(`tid`)
      }
      ,t)
    }
)
  }
  ,n(function(){
    F()
  }
),c.PrettySelect=function(e){
    var t={
      width:`auto`,search_contains:1,inherit_select_classes:!0,enable_split_word_search:!0,disable_search:c.isPositive(e.data(`search`))?0:1
    }
    ;e.chosen(t),e.trigger(`chosen:updated`)
  }
  ,L=function(e){
    this.constructor(e)
  }
  ,L.prototype={
    constructor(e){
      this.$input=e.find(`.CreateThreadSearch`).on(`input`,this.onChange.bind(this)),this.$createButton=e.find(`.CreateThreadButton`),this.$parent=e,this.$nodeList=this.$parent,this.$noResults=n(`<div class="ForumSearch-noResults muted"/>`).text(s(`no_results_found`)).hide().insertAfter(this.$parent.find(`.nodeList.NodeList`)),this.shown=!1,this.$parent.on(`click`,`a`,this.clickForum.bind(this))
    }
    ,findChildList(e){
      if(e.children(`ol`).length)return e.children(`ol`);let t=e.children(`div`);for(let e=0;e<t.length;e++){
        let r=this.findChildList(n(t[e]));if(r)return r
      }
      return null
    }
    ,recursiveSearch(e,t){
      if(t===this.$parent[0])return!0;let r=n(t),i=r.children(`div`).find(`.nodeTitle`).first(),a=this.findChildList(r),o=!1;if(a){
        let t=a.children(`.node`);for(let n=0;n<t.length;n++)this.recursiveSearch(e,t[n])&&(o=!0)
      }
      if(a){
        let t=i.find(`.ExpandSubForumList`);o?(a.show(),t.show(),t.addClass(`expanded`)):(a.hide(),t.hide(),t.removeClass(`expanded`)),e.length||(t.show(),r.is(`.current`)&&(a.show(),t.addClass(`expanded`)))
      }
      function s(e){
        for(var t={
          q:`й`,w:`ц`,e:`у`,r:`к`,t:`е`,y:`н`,u:`г`,i:`ш`,o:`щ`,p:`з`,"[":`х`,"]":`ъ`,a:`ф`,s:`ы`,d:`в`,f:`а`,g:`п`,h:`р`,j:`о`,k:`л`,l:`д`,";":`ж`,"'":`э`,z:`я`,x:`ч`,c:`с`,v:`м`,b:`и`,n:`т`,m:`ь`,",":`б`,".":`ю`,Q:`Й`,W:`Ц`,E:`У`,R:`К`,T:`Е`,Y:`Н`,U:`Г`,I:`Ш`,O:`Щ`,P:`З`,A:`Ф`,S:`Ы`,D:`В`,F:`А`,G:`П`,H:`Р`,J:`О`,K:`Л`,L:`Д`,Z:`?`,X:`ч`,C:`С`,V:`М`,B:`И`,N:`Т`,M:`Ь`
        }
        ,n=``,r=0;r<e.length;r++)n+=t[e.charAt(r)]||e.charAt(r);return n
      }
      function c(e){
        for(var t={
          й:`q`,ц:`w`,у:`e`,к:`r`,е:`t`,н:`y`,г:`u`,ш:`i`,щ:`o`,з:`p`,х:`[`,ъ:`]`,ф:`a`,ы:`s`,в:`d`,а:`f`,п:`g`,р:`h`,о:`j`,л:`k`,д:`l`,ж:`;`,э:`'`,я:`z`,ч:`X`,с:`c`,м:`v`,и:`b`,т:`n`,ь:`m`,б:`,`,ю:`.`,Й:`Q`,Ц:`W`,У:`E`,К:`R`,Е:`T`,Н:`Y`,Г:`U`,Ш:`I`,Щ:`O`,З:`P`,Х:`[`,Ъ:`]`,Ф:`A`,Ы:`S`,В:`D`,А:`F`,П:`G`,Р:`H`,О:`J`,Л:`K`,Д:`L`,Ж:`;`,Э:`'`,"?":`Z`,С:`C`,М:`V`,И:`B`,Т:`N`,Ь:`M`,Б:`,`,Ю:`.`
        }
        ,n=``,r=0;r<e.length;r++)n+=t[e.charAt(r)]||e.charAt(r);return n
      }
      let l=i.text().trim().toLowerCase(),u=l.indexOf(s(e))!==-1||l.indexOf(c(e))!==-1;return u&&e.length&&r.is(`.level_1`)&&(u=!1),o&&(u=!0),u?r.show():r.hide(),r.is(`.level-n`)?u&&e.length:u
    }
    ,onChange(){
      let e=this.$input.val().toLowerCase(),t=this.$parent.find(`.NodeList`),r=t.find(`li`),i=r.length,a=!1;for(let t=0;t<i;t++)this.recursiveSearch(e,n(r[t]))&&(a=!0);let o=t.height(),s=o!==this.prevNodeListHeight;this.prevNodeListHeight=o,a?this.$noResults.hide():this.$noResults.show(),s&&this.$parent.scrollbar()
    }
    ,clickForum(e){
      e.preventDefault();let t=n(e.currentTarget),r=t.attr(`href`);if(!r)return this.$createButton.prop(`disabled`,!0).hide().addClass(`hidden`);let i=t.text().trim();if(!i)return this.$createButton.prop(`disabled`,!0).hide().addClass(`hidden`);if(t.closest(`li`).hasClass(`noLoad`))return this.$createButton.text(t.closest(`li`).data(`noloadtitle`)).attr(`disabled`,!0).addClass(`disabled`);this.$createButton.text(s(`create_thread_in`,{
        text:i
      }
)).show().removeClass(`hidden`).removeClass(`disabled`).removeAttr(`disabled`).attr(`href`,r.replace(/\/$/,``)+`/create-thread`)
    }
  }
  ,c.ForumSearch=function(e){
    this.constructor(e)
  }
  ,c.ForumSearch.prototype={
    _registerEvents(){
      this.$button.add(this.$input).add(this.$clear).off(`click`).off(`input`),this.$button.on(`click`,this.toggleMenu.bind(this)),this.$input.on(`input`,this.onChange.bind(this)),this.$clear.on(`click`,this.onClear.bind(this))
    }
    ,constructor(e){
      if(this.$button=e.closest(`.NodeList.forums`).find(`.ForumSearch`),!this.$button.length)return;this.$input=n(`<input type="text" class="ForumSearch-input textCtrl">`).attr(`placeholder`,s(`search`)),this.$clear=n(`<i class="ForumSearch-close far fa-times"></i>`),this._registerEvents(),this.$container=n(`<div></div>`).append(this.$input,this.$clear),this.$parent=e,this.$noResults=w();let t=this;this.tippy=tippy(this.$button[0],{
        content:this.$container[0],trigger:`manual`,animation:`shift-toward`,interactive:!0,animateFill:!1,zIndex:n(`.xenOverlay`).length?11111:9e3,placement:`bottom`,theme:`popup`,arrow:!0,onShown:function(){
          t.$input.trigger(`focus`),t.$button.addClass(`ForumSearch_active`)
        }
        ,onHide:function(){
          t.$button.removeClass(`ForumSearch_active`)
        }
        ,onHidden:function(){
          t.shown=!1
        }
      }
),this.shown=!1
    }
    ,toggleMenu(e){
      e.preventDefault(),e.stopPropagation(),this.shown=!this.shown,this.shown?(this._registerEvents(),this.tippy.show()):this.tippy.hide()
    }
    ,findChildList(e){
      if(e.children(`ol`).length)return e.children(`ol`);let t=e.children(`div`);for(let e=0;e<t.length;e++){
        let r=this.findChildList(n(t[e]));if(r)return r
      }
      return null
    }
    ,recursiveSearch(e,t){
      if(t===this.$parent[0])return!0;let r=n(t),i=r.children(`div`).find(`.nodeTitle`).first(),a=this.findChildList(r),o=!1;if(a){
        let t=a.children(`.node`);for(let n of Array.from(t))this.recursiveSearch(e,n)&&(o=!0)
      }
      if(a){
        let t=i.find(`.ExpandSubForumList`);o?(a.show(),t.show(),t.addClass(`expanded`)):(a.hide(),t.hide(),t.removeClass(`expanded`)),e.length||(t.show(),r.is(`.current`)&&(a.show(),t.addClass(`expanded`)))
      }
      function s(e){
        for(var t={
          q:`й`,w:`ц`,e:`у`,r:`к`,t:`е`,y:`н`,u:`г`,i:`ш`,o:`щ`,p:`з`,"[":`х`,"]":`ъ`,a:`ф`,s:`ы`,d:`в`,f:`а`,g:`п`,h:`р`,j:`о`,k:`л`,l:`д`,";":`ж`,"'":`э`,z:`я`,x:`ч`,c:`с`,v:`м`,b:`и`,n:`т`,m:`ь`,",":`б`,".":`ю`,Q:`Й`,W:`Ц`,E:`У`,R:`К`,T:`Е`,Y:`Н`,U:`Г`,I:`Ш`,O:`Щ`,P:`З`,A:`Ф`,S:`Ы`,D:`В`,F:`А`,G:`П`,H:`Р`,J:`О`,K:`Л`,L:`Д`,Z:`?`,X:`ч`,C:`С`,V:`М`,B:`И`,N:`Т`,M:`Ь`
        }
        ,n=``,r=0;r<e.length;r++)n+=t[e.charAt(r)]||e.charAt(r);return n
      }
      function c(e){
        for(var t={
          й:`q`,ц:`w`,у:`e`,к:`r`,е:`t`,н:`y`,г:`u`,ш:`i`,щ:`o`,з:`p`,х:`[`,ъ:`]`,ф:`a`,ы:`s`,в:`d`,а:`f`,п:`g`,р:`h`,о:`j`,л:`k`,д:`l`,ж:`;`,э:`'`,я:`z`,ч:`X`,с:`c`,м:`v`,и:`b`,т:`n`,ь:`m`,б:`,`,ю:`.`,Й:`Q`,Ц:`W`,У:`E`,К:`R`,Е:`T`,Н:`Y`,Г:`U`,Ш:`I`,Щ:`O`,З:`P`,Х:`[`,Ъ:`]`,Ф:`A`,Ы:`S`,В:`D`,А:`F`,П:`G`,Р:`H`,О:`J`,Л:`K`,Д:`L`,Ж:`;`,Э:`'`,"?":`Z`,С:`C`,М:`V`,И:`B`,Т:`N`,Ь:`M`,Б:`,`,Ю:`.`
        }
        ,n=``,r=0;r<e.length;r++)n+=t[e.charAt(r)]||e.charAt(r);return n
      }
      let l=i.text().trim().toLowerCase(),u=l.indexOf(e)!==-1||l.indexOf(s(e))!==-1||l.indexOf(c(e))!==-1;return u&&e.length&&r.is(`.level_1`)&&(u=!1),o&&(u=!0),u?r.show():r.hide(),r.is(`.level-n`)?u&&e.length:u
    }
    ,onChange(){
      n(`.NodeList.forums`).addClass(`loading`),clearTimeout(this._searchTimer),this._searchTimer=setTimeout(this._performSearch.bind(this),200)
    }
    ,_performSearch(){
      let e=this.$input.val().toLowerCase();e.length?n(`.NodeList.forums`).find(`.PersonalTabs`).hide():n(`.NodeList.forums`).find(`.PersonalTabs`).show();let t=!1,r=n(`.NodeList.forums`).children(`li`);for(let i=0;i<r.length;i++)this.recursiveSearch(e,n(r[i]))&&(t=!0);t?this.$noResults.hide():this.$noResults.show(),n(`.NodeList.forums`).removeClass(`loading`)
    }
    ,onClear(){
      let e=this.$input;e.val().length?(e.val(``),this.onChange()):this.tippy.hide()
    }
  }
  ,c.ForumSearchInline=function(e){
    this.constructor(e)
  }
  ,c.ForumSearchInline.prototype=n.extend({
  }
  ,c.ForumSearch.prototype,{
    _registerEvents(){
      this.$input.add(this.$clear).off(`click`).off(`input`),this.$input.on(`input`,this.onChange.bind(this)),this.$clear.on(`click`,this.onClear.bind(this))
    }
    ,constructor(e){
      this.$container=e,this.$input=e.find(`.ForumSearch-input`),this.$clear=e.find(`.ForumSearch-close`),this.$parent=e.closest(`.NodeList.forums`).find(`.node0`).first(),this.$parent.length||(this.$parent=n(`.NodeList.forums .node0`).first()),this.$noResults=w(),this._registerEvents(),this.$container.toggleClass(`hasValue`,this.$input.val().length>0),this.$input.val().length&&this._performSearch()
    }
    ,onChange(){
      c.ForumSearch.prototype.onChange.call(this),this.$container.toggleClass(`hasValue`,this.$input.val().length>0)
    }
    ,onClear(){
      this.$input.val(``),this.onChange(),this.$input.trigger(`focus`)
    }
  }
),c.SortableTabs=function(e){
    if(c.isTouchBrowser())return;let t=e.find(`.personalTab[data-title]`);t.wrapAll(`<ul>`);let r=t.parent(`ul`);if(!r.length)return;function i(){
      let e=[];return r.find(`.personalTab[data-title]`).each(function(){
        e.push(n(this).attr(`data-title`))
      }
),e
    }
    function a(){
      let t={
        tabs:i()
      }
      ;c.ajax(e.data(`save-url`),t,function(e){
        c.hasResponseError(e)||c.alert(e._redirectMessage,``,5e3,null,`success`)
      }
      ,{
        method:`POST`
      }
)
    }
    new p(r.get(0),{
      delay:150,delayOnTouchOnly:!0,ghostClass:`sortable-holding-item`,draggable:`li`,onEnd:function(e){
        e.oldIndex!==e.newIndex&&a()
      }
    }
)
  }
  ,c.ThreadListDateRangeFilter=function(e){
    var t=e.find(`.dateRangePickerInput`);if(!t.length)return;var n=e.find(t.data(`startdate`)),r=e.find(t.data(`enddate`)),i=e.find(t.data(`periodlabel`)),a=e.find(`input.ctrl_filter_by_post_date`),o=!1;function l(e,t){
      return Object.keys(e).find(function(n){
        return e[n]===t
      }
)
    }
    function u(e,u,d){
      t.find(`span.title`).html(s(`market_from`)+` `+e.format(`D.MM.YY`)+` `+s(`to`).toLowerCase()+` `+u.format(`D.MM.YY`));var f=l(c.phrases,d);f&&i.val(f),n.val(_(e).format()),r.val(_(u).format()),o&&a.prop(`checked`,f!==`all_the_time`).trigger(`change`),o=!0
    }
    var d,f;parseInt(t.data(`def-time`))?(d=_().subtract(1,`month`).startOf(`month`),f=_().endOf(`month`)):(d=_(n.val()),f=_(r.val()));var p=[{
      key:`all_the_time`,start:_(`07.03.2013`,`DD.MM.YYYY`),end:_().endOf(`day`)
    }
    ,{
      key:`today`,start:_().startOf(`day`),end:_().endOf(`day`)
    }
    ,{
      key:`yesterday`,start:_().subtract(1,`days`).startOf(`day`),end:_().subtract(1,`days`).endOf(`day`)
    }
    ,{
      key:`last_7_days`,start:_().subtract(6,`days`),end:_()
    }
    ,{
      key:`last_30_days`,start:_().subtract(29,`days`),end:_()
    }
    ,{
      key:`this_month`,start:_().startOf(`month`),end:_().endOf(`month`)
    }
    ,{
      key:`past_month`,start:_().subtract(1,`month`).startOf(`month`),end:_().subtract(1,`month`).endOf(`month`)
    }
    ,{
      key:`this_year`,start:_().startOf(`year`),end:_().endOf(`day`)
    }
    ,{
      key:`past_year`,start:_().subtract(1,`year`).startOf(`year`),end:_().subtract(1,`year`).endOf(`year`)
    }
],m=h(t,{
      start:d.toDate(),end:f.toDate(),minYear:2013,maxYear:new Date().getFullYear(),timePicker:!0,locale:c.visitor.language_id===1?`en`:`ru`,labels:{
        apply:s(`apply`),cancel:s(`cancel`),reset:s(`reset`),from:s(`market_from`),to:s(`date_range_to`).toLowerCase(),customRange:s(`other_period`),goTo:s(`go_to`),calendar:s(`calendar`)
      }
      ,presets:p.map(function(e){
        return{
          key:e.key,label:s(e.key),start:e.start.toDate(),end:e.end.toDate()
        }
      }
),resetPresetKey:`all_the_time`,onApply:function(e,t,n){
        u(_(e),_(t),n)
      }
      ,onReset:function(){
        var e=p.find(function(e){
          return e.key===`all_the_time`
        }
);t.find(`span.title`).html(s(`market_from`)+` `+e.start.format(`D.MM.YY`)+` `+s(`to`).toLowerCase()+` `+e.end.format(`D.MM.YY`)),n.val(``),r.val(``),i.val(``),a.prop(`checked`,!1).trigger(`change`)
      }
    }
);t.data(`daterangepicker`,m),u(d,f,i.val()||s(`all_the_time`))
  }
  ,c.register(`.threadListDateRangeFilter`,`XenForo.ThreadListDateRangeFilter`),c.register(`#SelectForumsForm`,`XenForo.CreateTabForm`),c.register(`#ExcludeForumsForm`,`XenForo.ExcludeForumsForm`),c.register(`.NodeList.forums`,`XenForo.ForumList`),c.register(`.DiscussionList`,`XenForo.LiveForumPages`),c.register(`.CreateThreadButton`,`XenForo.CreateThreadButton`),c.register(`.HideThread`,`XenForo.HideThread`),c.register(`#content select:not(#ModerationSelect)`,`XenForo.PrettySelect`),c.register(`.CreatePersonalExtendedTab`,`XenForo.CreatePersonalExtendedTab`),c.register(`#NodeListToggle`,`XenForo.NodeListToggle`),c.register(`.PersonalTabs`,`XenForo.SortableTabs`),c.register(`.node0`,`XenForo.ForumSearch`),c.register(`.ForumSearch-inline`,`XenForo.ForumSearchInline`),R=`.NodeList.forums li.node.forum:not(.personalTab):not(.createPersonalTabNode):not(.link):not(.node0)`,z=null,B=null,V=null,H=null,U=null,W=0,G=!1,n(document).on(`touchstart`,R,function(e){
    if(!T()||!N(e,this))return;let t=n(this),r=e.originalEvent||e,i=r.targetTouches&&r.targetTouches[0];if(!i)return;G=!1,W=Date.now(),U={
      x:i.clientX,y:i.clientY
    }
    ;let a=i.clientX,o=i.clientY;H=setTimeout(()=>{
      var e;H=null,U=null,G=!0,(e=window.getSelection())==null||e.removeAllRanges(),j({
        type:`longpress`,preventDefault(){
        }
        ,clientX:a,clientY:o
      }
      ,t)
    }
    ,500)
  }
),n(document).on(`touchmove`,R,function(e){
    if(!U)return;let t=e.originalEvent||e,n=t.touches&&t.touches[0];n&&(Math.abs(n.clientX-U.x)>10||Math.abs(n.clientY-U.y)>10)&&M()
  }
),n(document).on(`touchend touchcancel`,R,function(){
    W=Date.now(),M()
  }
),n(document).on(`contextmenu`,R,function(e){
    if(N(e,this)){
      if(U||G||Date.now()-W<1e3){
        e.preventDefault();return
      }
      j(e,n(this))
    }
  }
),n(document).on(`pointerdown keydown`,function(e){
    z&&n(e.target).closest(`.popup-menu`).length===0&&k()
  }
),[`touchend`,`click`].forEach(e=>{
    document.addEventListener(e,function(t){
      G&&(n(t.target).closest(R).length&&(t.preventDefault(),t.stopPropagation()),e===`click`&&(G=!1))
    }
    ,{
      capture:!0
    }
)
  }
)
}
);
K();
