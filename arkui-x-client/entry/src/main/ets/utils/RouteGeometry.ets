// Keep the existing calibration in its 330 × 556 display frame. The untouched
// HDUHELP resource is 3911 × 6586 pixels; these are display coordinates, not pixels.
const REFERENCE_WIDTH: number = 330;
const REFERENCE_IMAGE_HEIGHT: number = 556;
const REFERENCE_VIEWPORT_HEIGHT: number = 372;

export const ROUTE_MAP_ASPECT_RATIO: number = REFERENCE_WIDTH / REFERENCE_VIEWPORT_HEIGHT;

export interface RouteMapGeometry {
  width: number;
  viewportHeight: number;
  imageHeight: number;
  scale: number;
}

export interface RouteScreenPoint {
  x: number;
  y: number;
}

export function routeMapGeometry(containerWidth: number): RouteMapGeometry {
  const width = Number.isFinite(containerWidth) && containerWidth > 0 ? containerWidth : 0;
  const scale = width / REFERENCE_WIDTH;
  return {
    width: width,
    viewportHeight: REFERENCE_VIEWPORT_HEIGHT * scale,
    imageHeight: REFERENCE_IMAGE_HEIGHT * scale,
    scale: scale
  };
}

export function routeScreenPoint(x: number, y: number, geometry: RouteMapGeometry): RouteScreenPoint {
  // The route graph uses a 100 × 74 campus panel. Preserve its original offset
  // and extent while scaling both axes with the same factor as the image.
  return {
    x: (11.1 + x / 100 * 294.6) * geometry.scale,
    y: (53.9 + y / 74 * 299.2) * geometry.scale
  };
}
