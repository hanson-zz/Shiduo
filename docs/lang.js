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
