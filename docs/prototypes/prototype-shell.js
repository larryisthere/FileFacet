(() => {
  const pages = [
    { id: "manual-video-import", label: "手动导入" },
    { id: "folder-structure-tags", label: "目录标签导入" },
    { id: "smart-filters", label: "筛选与智能分类" },
    { id: "deferred-tag-editing", label: "标签编辑" },
    { id: "offline-library", label: "不可用视频" },
    { id: "media-source-inspector", label: "媒体检查器" },
    { id: "tag-sorting", label: "标签排序" },
    { id: "localization", label: "本地化" }
  ];

  const currentPage = document.body.dataset.prototypePage;
  const subtitle = document.body.dataset.prototypeSubtitle || "HTML 交互稿";
  const appMenuEnabled = document.body.dataset.prototypeAppMenu === "true";
  const fileMenuMode = document.body.dataset.prototypeFileMenu || "";

  function pageHref(pageID) {
    return pageID === currentPage ? "index.html" : `../${pageID}/index.html`;
  }

  function pageLink(page) {
    const active = page.id === currentPage;
    return `<a class="prototype-link${active ? " active" : ""}" href="${pageHref(page.id)}"${active ? ' aria-current="page"' : ""}>${page.label}</a>`;
  }

  function buildPanel() {
    const panel = document.createElement("aside");
    panel.className = "prototype-panel";
    panel.setAttribute("aria-label", "FileFacet 原型导航");
    panel.innerHTML = `
      <div class="prototype-panel-header">
        <div class="prototype-panel-title"><strong>FileFacet 原型</strong><span>${subtitle}</span></div>
        <button class="prototype-panel-toggle" id="togglePrototypePanel" title="收起原型导航" aria-label="收起原型导航" aria-expanded="true"><svg viewBox="0 0 18 18" aria-hidden="true"><path d="m11 4-5 5 5 5"></path></svg></button>
      </div>
      <div class="prototype-panel-scroll">
        <section class="prototype-group" aria-labelledby="prototypePagesTitle">
          <div class="prototype-group-title" id="prototypePagesTitle">原型页面</div>
          ${pages.map(pageLink).join("")}
        </section>
        <section class="prototype-group" aria-labelledby="prototypeGuideTitle">
          <div class="prototype-group-title" id="prototypeGuideTitle">规范</div>
          <a class="prototype-link${currentPage === "guidelines" ? " active" : ""}" href="${currentPage === "guidelines" ? "index.html" : "../guidelines/index.html"}"${currentPage === "guidelines" ? ' aria-current="page"' : ""}>原型规范</a>
        </section>
      </div>
      <span class="prototype-rail-label" aria-hidden="true">原型导航</span>
    `;

    const actionTemplate = document.getElementById("prototypePageActions");
    if (actionTemplate) panel.querySelector(".prototype-panel-scroll").append(actionTemplate.content);

    const footerTemplate = document.getElementById("prototypePanelFooter");
    if (footerTemplate) {
      const footer = document.createElement("div");
      footer.className = "prototype-panel-footer";
      footer.append(footerTemplate.content);
      panel.insertBefore(footer, panel.querySelector(".prototype-rail-label"));
    }

    return panel;
  }

  function appMenuMarkup() {
    if (!appMenuEnabled) return '<span class="prototype-menubar-label app-name">FileFacet</span>';
    return `
      <div class="prototype-menubar-wrap">
        <button class="prototype-menubar-button app-name" id="appMenuButton" aria-haspopup="menu" aria-expanded="false">FileFacet</button>
        <div class="prototype-menu-popover" id="appMenu" role="menu" hidden>
          <button class="prototype-menu-command" id="aboutMenuItem" role="menuitem"><span>关于 FileFacet</span></button>
          <div class="prototype-menu-divider"></div>
          <button class="prototype-menu-command" id="settingsMenuItem" role="menuitem"><span>设置…</span><span class="prototype-menu-shortcut">⌘,</span></button>
          <div class="prototype-menu-divider"></div>
          <button class="prototype-menu-command" role="menuitem"><span>退出 FileFacet</span><span class="prototype-menu-shortcut">⌘Q</span></button>
        </div>
      </div>
    `;
  }

  function fileMenuMarkup() {
    if (fileMenuMode !== "import") return '<span class="prototype-menubar-label">文件</span>';
    return `
      <div class="prototype-menubar-wrap">
        <button class="prototype-menubar-button" id="fileMenuButton" aria-haspopup="menu" aria-expanded="false">文件</button>
        <div class="prototype-menu-popover" id="fileMenu" role="menu" hidden>
          <button class="prototype-menu-command" id="importMenuItem" role="menuitem"><span>导入视频与文件夹…</span><span class="prototype-menu-shortcut">⇧⌘I</span></button>
          <div class="prototype-menu-divider"></div>
          <button class="prototype-menu-command" role="menuitem"><span>关闭窗口</span><span class="prototype-menu-shortcut">⌘W</span></button>
        </div>
      </div>
    `;
  }

  function buildMenubar() {
    const menubar = document.createElement("header");
    menubar.className = "app-menubar";
    menubar.setAttribute("aria-label", "应用菜单栏");
    menubar.innerHTML = `
      ${appMenuMarkup()}
      ${fileMenuMarkup()}
      <span class="prototype-menubar-label">编辑</span>
      <span class="prototype-menubar-label">显示</span>
      <span class="prototype-menubar-label">窗口</span>
      <span class="prototype-menubar-label">帮助</span>
    `;
    return menubar;
  }

  const panel = buildPanel();
  const menubar = buildMenubar();
  document.body.prepend(menubar);
  document.body.prepend(panel);

  const toggle = document.getElementById("togglePrototypePanel");

  function setCollapsed(collapsed) {
    document.body.classList.toggle("prototype-panel-collapsed", collapsed);
    toggle.setAttribute("aria-expanded", String(!collapsed));
    toggle.setAttribute("aria-label", collapsed ? "展开原型导航" : "收起原型导航");
    toggle.title = collapsed ? "展开原型导航" : "收起原型导航";
  }

  toggle.addEventListener("click", () => {
    setCollapsed(!document.body.classList.contains("prototype-panel-collapsed"));
  });

  document.addEventListener("keydown", event => {
    const isEditing = event.target.matches?.("input, select, textarea, [contenteditable='true']");
    if (isEditing || event.metaKey || event.ctrlKey || event.altKey || event.key.toLowerCase() !== "p") return;
    event.preventDefault();
    setCollapsed(!document.body.classList.contains("prototype-panel-collapsed"));
  });

  window.FileFacetPrototypeShell = { setCollapsed };
})();
