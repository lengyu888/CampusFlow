export interface NavigationStack {
  root: number;
  routes: number[];
}

export interface AppNavigationState {
  root: number;
  stacks: NavigationStack[];
}

export function isRootRoute(route: number): boolean {
  return route === 0 || route === 1 || route === 2 || route === 8;
}

export function createNavigation(): AppNavigationState {
  return {
    root: 0,
    stacks: [
      { root: 0, routes: [0] }, { root: 1, routes: [1] },
      { root: 2, routes: [2] }, { root: 8, routes: [8] }
    ]
  };
}

function copyNavigation(state: AppNavigationState): AppNavigationState {
  return {
    root: state.root,
    stacks: state.stacks.map((stack: NavigationStack): NavigationStack => ({ root: stack.root, routes: stack.routes.slice() }))
  };
}

export function currentRoute(state: AppNavigationState): number {
  const stack = state.stacks.find((item: NavigationStack) => item.root === state.root);
  return stack !== undefined && stack.routes.length > 0 ? stack.routes[stack.routes.length - 1] : state.root;
}

export function selectRoot(state: AppNavigationState, root: number, reset: boolean = false): AppNavigationState {
  const next = copyNavigation(state);
  if (!isRootRoute(root)) { return next; }
  next.root = root;
  if (reset) {
    next.stacks = next.stacks.map((stack: NavigationStack): NavigationStack =>
      stack.root === root ? { root: root, routes: [root] } : stack);
  }
  return next;
}

export function openSecondary(state: AppNavigationState, route: number): AppNavigationState {
  const next = copyNavigation(state);
  // Route numbers are the established Skills/Profile/History/Route/Services/Timetable pages.
  if (![3, 4, 5, 6, 7, 9].includes(route) || currentRoute(state) === route) { return next; }
  next.stacks = next.stacks.map((stack: NavigationStack): NavigationStack =>
    stack.root === next.root ? { root: stack.root, routes: stack.routes.concat(route) } : stack);
  return next;
}

export function hasBack(state: AppNavigationState): boolean {
  const stack = state.stacks.find((item: NavigationStack) => item.root === state.root);
  return stack !== undefined && stack.routes.length > 1;
}

export function backNavigation(state: AppNavigationState): AppNavigationState {
  const next = copyNavigation(state);
  next.stacks = next.stacks.map((stack: NavigationStack): NavigationStack =>
    stack.root === next.root && stack.routes.length > 1 ?
      { root: stack.root, routes: stack.routes.slice(0, -1) } : stack);
  return next;
}
