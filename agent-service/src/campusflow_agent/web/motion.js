(() => {
  "use strict";

  if (!window.gsap) return;

  const { gsap } = window;
  const media = gsap.matchMedia();
  const observed = new WeakSet();
  const activeObservers = [];

  const visible = (element) => element instanceof HTMLElement && !element.hidden && element.offsetParent !== null;

  const revealOverlay = (element) => {
    if (!visible(element)) return;
    const mobile = window.matchMedia("(max-width: 680px)").matches;
    gsap.fromTo(element, { autoAlpha: 0, x: mobile ? 0 : 28, y: mobile ? 32 : 0 }, { autoAlpha: 1, x: 0, y: 0, duration: 0.34, ease: "power3.out", clearProps: "opacity,visibility,transform" });
  };

  const watch = (root) => {
    if (!root || observed.has(root)) return;
    observed.add(root);
    const observer = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        const target = mutation.target;
        if (target.matches("#historyDrawer, #skillDrawer") && visible(target)) revealOverlay(target);
      }
    });
    observer.observe(root, { attributes: true, attributeFilter: ["hidden"], subtree: true });
    activeObservers.push(observer);
  };

  media.add("(prefers-reduced-motion: no-preference)", () => {
    watch(document.body);

    return () => {
      activeObservers.splice(0).forEach((observer) => observer.disconnect());
      gsap.killTweensOf("*");
    };
  });
})();
