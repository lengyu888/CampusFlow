"""Evidence boundaries via real models, SQLite snapshots and authenticated HTTP."""
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest
from test_api import ONBOARDING_PAYLOAD, complete_onboarding, register

from campusflow_agent.accounts import AccountStore
from campusflow_agent.evidence import cached_evidence, campus_supported, safe_source_url
from campusflow_agent.schemas import TimetableSaveRequest, WeatherForecast
from campusflow_agent.store import CampusStore
from campusflow_agent.timetable_service import TimetableService
from campusflow_agent.weather import WeatherService

NOW = datetime(2026, 10, 18, tzinfo=UTC)


@pytest.mark.parametrize('url', [
    'http://example.org', 'https://user:pass@example.org', 'https://example.org/?token=secret',
    'https://example.org/#token', 'javascript:alert(1)', '//example.org',
    'https://example.org/\nsecret', 'https://example.org/ a', '', None,
])
def test_sources_never_expose_credential_urls(url):
    assert safe_source_url(url) is None


def test_public_source_retained():
    assert safe_source_url('https://open-meteo.com/en/docs') == 'https://open-meteo.com/en/docs'


@pytest.mark.parametrize('stamp,state', [
    (NOW - timedelta(seconds=299), 'fresh'),
    (NOW - timedelta(seconds=300), 'stale'),
    (NOW - timedelta(days=30), 'stale'),
    (None, 'unverified'), ('broken', 'unverified'),
    (NOW.replace(tzinfo=None), 'unverified'),
    (NOW + timedelta(minutes=6), 'unverified'),
])
def test_cache_policy_uses_actual_timestamp(stamp, state):
    result = cached_evidence('x', 'x', stamp, 300, now=NOW)
    assert result.status == state
    if state == 'unverified':
        assert result.updated_at is None and result.expires_at is None
    else:
        assert result.updated_at == stamp
        assert result.expires_at == stamp + timedelta(seconds=300)


@pytest.mark.parametrize('school,campus,expected', [
    ('杭州电子科技大学', '下沙校区', True), ('HDU', 'xiasha', True),
    ('杭电', '下沙', True), ('', '', False), ('其他学校', '下沙校区', False),
    ('杭州电子科技大学', '青山湖校区', False),
])
def test_campus_scope(school, campus, expected):
    assert campus_supported(school, campus) is expected


def test_timetable_source_is_persistent_and_retry_does_not_refresh(tmp_path):
    database = str(tmp_path / 'evidence.sqlite')
    accounts, store = AccountStore(database), CampusStore(database)
    user = accounts.register(email='evidence@example.invalid', password='synthetic-only',
                             display_name='测试', api_key_encrypted='', api_key_hint='')
    service = TimetableService(accounts, store, clock=lambda: NOW)
    before = service.snapshot(user.user_id)
    assert before.entries == [] and before.evidence[0].status == 'unverified'
    payload = TimetableSaveRequest(operation_id=uuid4(), expected_revision=before.revision,
                                   entries=ONBOARDING_PAYLOAD['timetable'])
    service.save(user.user_id, payload)
    first = service.snapshot(user.user_id)
    assert first.evidence[0].updated_at == NOW and first.evidence[0].kind == 'user'
    service.clock = lambda: NOW + timedelta(hours=1)
    service.save(user.user_id, payload)
    assert service.snapshot(user.user_id).evidence == first.evidence
    reopened = TimetableService(AccountStore(database), CampusStore(database))
    assert reopened.snapshot(user.user_id) == first
    # Snapshot reads content and metadata atomically in a single SQLite row.
    statements = []
    accounts._connection.set_trace_callback(statements.append)
    service.snapshot(user.user_id)
    assert sum('FROM users' in sql for sql in statements) == 1


async def test_weather_auth_date_and_actual_identity(client, monkeypatch):
    calls = []
    async def forecast(self, date, school, campus):
        calls.append((str(date), school, campus))
        return WeatherForecast(date=str(date), location_label='合成测试，未访问网络')
    monkeypatch.setattr(WeatherService, 'forecast', forecast)
    assert (await client.get('/api/v1/weather')).status_code == 401
    await register(client)
    await complete_onboarding(client)
    assert (await client.get('/api/v1/weather?date=2026-10-18')).status_code == 200
    assert calls == [('2026-10-18', '杭州电子科技大学', '下沙校区')]
    for value in ('bad', '20261018', '2026-02-30'):
        result = await client.get('/api/v1/weather', params={'date': value})
        assert result.status_code == 422 and result.json()['code'] == 'WEATHER_DATE_INVALID'
    assert len(calls) == 1


async def test_unknown_campus_never_receives_hdu_reference(client):
    await register(client)
    for path in ('/campus-data', '/campus-data/places', '/campus-data/notices',
                 '/campus-data/route?origin=图书馆&destination=六教'):
        response = await client.get('/api/v1' + path)
        assert response.status_code == 404
        assert response.json()['code'] == 'DATA_SCOPE_UNSUPPORTED'
    await client.put('/api/v1/onboarding', json={**ONBOARDING_PAYLOAD, 'campus': '青山湖校区'})
    assert (await client.get('/api/v1/campus-data')).status_code == 404


async def test_synced_hdu_sections_keep_same_source_as_raw_resource(client):
    await register(client)
    response = await client.put('/api/v1/hduhelp/pat',
                               json={'pat': 'hduhelp_pat_test_only_1234567890'})
    assert response.status_code == 200
    result = (await client.get('/api/v1/hduhelp/data')).json()
    sources = {item['resource']: item['evidence'] for item in result['resources']}
    assert sources
    for section in result['sections']:
        assert section['evidence'] == sources[section['resource']]
        assert section['evidence'][0]['status'] == 'fresh'
        assert section['evidence'][0]['updated_at']
        assert section['evidence'][0]['expires_at']
    assert 'hduhelp_pat_' not in str(sources)


async def test_live_campus_service_responses_are_timestamped(client):
    await register(client)
    await client.put('/api/v1/hduhelp/pat', json={'pat': 'hduhelp_pat_test_only_1234567890'})
    for path in ('/classrooms', '/classrooms/room-602/usage', '/electricity'):
        response = await client.get('/api/v1/campus-services' + path)
        assert response.status_code == 200
        source = response.json()['evidence'][0]
        assert source['status'] == 'fresh' and source['kind'] == 'remote'
        assert source['url'] == 'https://api.hduhelp.com'
