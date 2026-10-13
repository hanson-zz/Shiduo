/* 中文 / EN 切换：默认英文，浏览器语言是中文时默认中文；选择记在 localStorage。 */
(function () {
  var KEY = 'shiduo-lang';
  var root = document.documentElement;

  function current() { return root.getAttribute('data-lang') === 'zh' ? 'zh' : 'en'; }

  function apply(lang) {
    root.setAttribute('data-lang', lang);
    root.lang = lang === 'zh' ? 'zh-Hans' : 'en';
    var title = root.getAttribute('data-title-' + lang);
    if (title) document.title = title;
    var btn = document.getElementById('lang-toggle');
    if (btn) {
      btn.setAttribute('aria-label', lang === 'zh' ? 'Switch to English' : '切换到中文');
      btn.setAttribute('title', lang === 'zh' ? 'Switch to English' : '切换到中文');
    }
    // 截图：中文用 screenshots/x.png，英文优先用 screenshots/en/x.png（没有就退回中文图）。
    var shots = document.querySelectorAll('img[data-shot]');
    for (var i = 0; i < shots.length; i++) {
      var img = shots[i], name = img.getAttribute('data-shot');
      var zh = 'screenshots/' + name + '.png', en = 'screenshots/en/' + name + '.png';
      img.onerror = null;
      if (lang === 'en') {
        img.onerror = function () { this.onerror = null; this.src = 'screenshots/' + this.getAttribute('data-shot') + '.png'; };
        img.src = en;
      } else {
        img.src = zh;
      }
    }
  }

  apply(current());

  var btn = document.getElementById('lang-toggle');
  if (btn) {
    btn.addEventListener('click', function () {
      var next = current() === 'zh' ? 'en' : 'zh';
      try { localStorage.setItem(KEY, next); } catch (e) {}
      apply(next);
    });
  }
})();

/* 观看演示：弹窗播放；竖屏设备播放竖版视频。打开 #demo 链接时自动弹出。 */
(function () {
  var modal = document.getElementById('demo-modal');
  if (!modal) return;
  var video = document.getElementById('demo-video');
  function open(e) {
    if (e) e.preventDefault();
    var tall = window.innerHeight > window.innerWidth * 1.2;
    var src = tall ? 'demo/shiduo-demo-vertical.mp4' : 'demo/shiduo-demo.mp4';
    if (video.getAttribute('src') !== src) video.setAttribute('src', src);
    modal.hidden = false;
    var p = video.play(); if (p && p.catch) p.catch(function () {});
  }
  function close() { video.pause(); modal.hidden = true; if (location.hash === '#demo') history.replaceState(null, '', location.pathname); }
  var btns = document.querySelectorAll('[data-demo]');
  for (var i = 0; i < btns.length; i++) btns[i].addEventListener('click', open);
  document.getElementById('demo-close').addEventListener('click', close);
  modal.addEventListener('click', function (e) { if (e.target === modal) close(); });
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape' && !modal.hidden) close(); });
  if (location.hash === '#demo') open();
})();
