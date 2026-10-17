import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

// Exercise the actual pure ArkTS geometry helper; this is not a native UI test.
const source = readFileSync(new URL('../entry/src/main/ets/utils/RouteGeometry.ets', import.meta.url), 'utf8');
const { ROUTE_MAP_ASPECT_RATIO, routeMapGeometry, routeScreenPoint } =
  await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString('base64')}`);

function close(actual, expected) {
  assert.ok(Math.abs(actual - expected) < 1e-9, `${actual} differs from ${expected}`);
}

test('330 vp preserves the existing crop and calibrated route coordinates', () => {
  const geometry = routeMapGeometry(330);
  assert.deepEqual(geometry, { width: 330, viewportHeight: 372, imageHeight: 556, scale: 1 });
  assert.deepEqual(routeScreenPoint(0, 0, geometry), { x: 11.1, y: 53.9 });
  const bottomRight = routeScreenPoint(100, 74, geometry);
  close(bottomRight.x, 305.7);
  close(bottomRight.y, 353.1);
  const center = routeScreenPoint(50, 37, geometry);
  close(center.x, 158.4);
  close(center.y, 203.5);
});

for (const width of [240, 280, 330, 400, 720]) {
  test(`${width} vp keeps image, viewport, route and endpoint markers in the same frame`, () => {
    const geometry = routeMapGeometry(width);
    assert.equal(geometry.width, width);
    close(geometry.viewportHeight, width / ROUTE_MAP_ASPECT_RATIO);
    close(geometry.imageHeight / 556, width / 330);
    close(geometry.viewportHeight / geometry.imageHeight, 372 / 556);

    // Corners, midpoint and a non-integer route node cover translation and scale.
    for (const [x, y] of [[0, 0], [100, 0], [0, 74], [100, 74], [50, 37], [23.5, 61.25]]) {
      const point = routeScreenPoint(x, y, geometry);
      const referenceX = 11.1 + x / 100 * 294.6;
      const referenceY = 53.9 + y / 74 * 299.2;
      // Same fraction of the entire bitmap at every width, with no drift.
      close(point.x / geometry.width, referenceX / 330);
      close(point.y / geometry.imageHeight, referenceY / 556);
      const markerExtent = 8 * geometry.scale; // 7 vp radius plus half the 2 vp stroke.
      assert.ok(point.x - markerExtent >= 0);
      assert.ok(point.x + markerExtent <= geometry.width);
      assert.ok(point.y - markerExtent >= 0);
      assert.ok(point.y + markerExtent <= geometry.viewportHeight);
    }
  });
}

test('repeated narrow / landscape resizing never accumulates scaling or changes route data', () => {
  const route = Object.freeze([
    Object.freeze({ x: 10, y: 20 }), Object.freeze({ x: 45, y: 30 }), Object.freeze({ x: 88, y: 65 })
  ]);
  const snapshot = JSON.stringify(route);
  let baseline;
  for (const width of [330, 240, 720, 280, 400, 330]) {
    const geometry = routeMapGeometry(width);
    const points = route.map((point) => routeScreenPoint(point.x, point.y, geometry));
    if (!baseline) baseline = points;
    if (width === 330) assert.deepEqual(points, baseline);
  }
  assert.equal(JSON.stringify(route), snapshot);
});

test('layout widths that are not ready produce zero geometry, never NaN', () => {
  for (const width of [0, -1, NaN, Infinity, -Infinity]) {
    assert.deepEqual(routeMapGeometry(width), { width: 0, viewportHeight: 0, imageHeight: 0, scale: 0 });
  }
});
