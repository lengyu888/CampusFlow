(() => {
  "use strict";

  if (!window.gsap) return;

  const { gsap } = window;
  const media = gsap.matchMedia();
  const observed = new WeakSet();
  const activeObservers = [];

  const visible = (element) => element instanceof HTMLElement && !element.hidden && element.offsetParent !== null;

  const revealSurface = (surface) => {
    if (!visible(surface)) return;
    const heading = surface.querySelector(":scope > .today-hero, :scope > .surface-heading, :scope > .workspace");
    const cards = surface.querySelectorAll(":scope > .today-grid > *, :scope > .suggestion-strip, :scope > .planning-stats > *, :scope > .plan-board > *, :scope > .skill-toolbar, :scope > .skill-grid > *, :scope > .skill-audit-panel");
    const timeline = gsap.timeline({ defaults: { ease: "power3.out" } });
    if (heading) timeline.fromTo(heading, { autoAlpha: 0, y: 18 }, { autoAlpha: 1, y: 0, duration: 0.48, clearProps: "opacity,visibility,transform" });
    if (cards.length) timeline.fromTo(cards, { autoAlpha: 0, y: 16 }, { autoAlpha: 1, y: 0, duration: 0.42, stagger: 0.055, clearProps: "opacity,visibility,transform" }, "-=0.26");
  };

  const revealGate = (gate) => {
    if (!visible(gate)) return;
    gsap.timeline({ defaults: { ease: "power3.out" } })
      .fromTo(".gate-story .brand", { autoAlpha: 0, y: -12 }, { autoAlpha: 1, y: 0, duration: 0.4 })
      .fromTo(".gate-copy > *", { autoAlpha: 0, y: 22 }, { autoAlpha: 1, y: 0, duration: 0.55, stagger: 0.07 }, "-=0.15")
      .fromTo(".auth-card", { autoAlpha: 0, y: 24, scale: 0.985 }, { autoAlpha: 1, y: 0, scale: 1, duration: 0.58 }, "-=0.4");
  };

  const revealOverlay = (element) => {
    if (!visible(element)) return;
    const mobile = window.matchMedia("(max-width: 680px)").matches;
    gsap.fromTo(element, { autoAlpha: 0, x: mobile ? 0 : 28, y: mobile ? 32 : 0 }, { autoAlpha: 1, x: 0, y: 0, duration: 0.34, ease: "power3.out", clearProps: "opacity,visibility,transform" });
  };

  const revealNewItem = (element) => {
    gsap.fromTo(element, { autoAlpha: 0, y: 12, scale: 0.99 }, { autoAlpha: 1, y: 0, scale: 1, duration: 0.32, ease: "power2.out", clearProps: "opacity,visibility,transform" });
  };

  const watch = (root) => {
    if (!root || observed.has(root)) return;
    observed.add(root);
    const observer = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        if (mutation.type === "attributes" && mutation.attributeName === "hidden") {
          const target = mutation.target;
          if (!visible(target)) continue;
          if (target.matches("[data-app-surface]")) revealSurface(target);
          else if (target.matches("#historyDrawer, #skillDrawer")) revealOverlay(target);
          else if (target.matches("#authView")) revealGate(target);
          else if (target.matches(".settings-panel, .setup-step")) revealNewItem(target);
        }
        mutation.addedNodes.forEach((node) => {
          if (!(node instanceof HTMLElement)) return;
          if (node.matches(".message, .trace-card, .action-card, .plan-item, .skill-card, .history-item")) revealNewItem(node);
        });
      }
    });
    observer.observe(root, { attributes: true, attributeFilter: ["hidden"], childList: true, subtree: true });
    activeObservers.push(observer);
  };

  media.add("(prefers-reduced-motion: no-preference)", () => {
    const initialView = [document.querySelector("#authView"), document.querySelector("#onboardingView"), document.querySelector("#appView"), document.querySelector("#settingsView")].find(visible);
    if (initialView?.id === "authView") revealGate(initialView);
    if (initialView?.id === "appView") {
      gsap.fromTo(".app-topbar", { autoAlpha: 0, y: -12 }, { autoAlpha: 1, y: 0, duration: 0.4, ease: "power3.out" });
      gsap.fromTo(".app-nav button", { autoAlpha: 0, x: -10 }, { autoAlpha: 1, x: 0, duration: 0.35, stagger: 0.04, ease: "power2.out" });
      const current = document.querySelector("[data-app-surface]:not([hidden])");
      if (current) revealSurface(current);
    }
    watch(document.body);

    return () => {
      activeObservers.splice(0).forEach((observer) => observer.disconnect());
      gsap.killTweensOf("*");
    };
  });
})();
