const { chromium } = require('playwright');

const BASE_URL = 'https://queene189123-ai.github.io/obyasnyarium/';
const TIMEOUT = 20000;

(async () => {
  const browser = await chromium.launch({ headless: true });
  // Run the host on a phone-sized viewport and the guest on desktop.
  const hostContext = await browser.newContext({
    viewport: { width: 390, height: 844 },
    deviceScaleFactor: 1,
    isMobile: true,
    hasTouch: true
  });
  const guestContext = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const host = await hostContext.newPage();
  const guest = await guestContext.newPage();
  const dialogs = [];

  for (const page of [host, guest]) {
    page.setDefaultTimeout(TIMEOUT);
    page.on('dialog', async dialog => {
      const expectedConfirm = dialog.type() === 'confirm' &&
        ['Закончить игру и показать итоговые очки всем игрокам?', 'Начать реванш? Счёт всех игроков обнулится.'].includes(dialog.message());
      if (!expectedConfirm) dialogs.push(dialog.type().toUpperCase() + ': ' + dialog.message());
      await dialog.accept();
    });
    page.on('pageerror', error => dialogs.push('PAGE_ERROR: ' + error.message));
  }

  async function enterOnline(page) {
    await page.goto(BASE_URL, { waitUntil: 'domcontentloaded' });
    await page.getByRole('button', { name: 'Играть онлайн' }).click();
  }

  async function assertNoHorizontalOverflow(page, label) {
    const dimensions = await page.evaluate(() => ({
      viewport: document.documentElement.clientWidth,
      content: document.documentElement.scrollWidth
    }));
    if (dimensions.content > dimensions.viewport + 2) {
      throw new Error('Horizontal overflow on mobile at ' + label + ': ' + JSON.stringify(dimensions));
    }
  }

  async function cleanup(page) {
    try {
      if (await page.locator('#online-hud-leave').isVisible()) {
        await page.locator('#online-hud-leave').click();
        await page.waitForTimeout(700);
      }
    } catch (_) {}
  }

  try {
    await enterOnline(host);
    await host.getByRole('button', { name: 'Создать комнату' }).click();
    await host.locator('#online-host-name').fill('CI Host');
    await host.getByRole('button', { name: 'Создать', exact: true }).click();
    await host.locator('#screen-online-lobby.active').waitFor();
    await assertNoHorizontalOverflow(host, 'host lobby');
    const code = (await host.locator('#online-room-code').innerText()).trim();
    if (!/^\d{5}$/.test(code)) throw new Error('Host received invalid room code: ' + code);

    await enterOnline(guest);
    await guest.getByRole('button', { name: 'Войти в комнату' }).click();
    await guest.locator('#online-join-name').fill('CI Guest');
    await guest.locator('#online-join-code').fill(code);
    await guest.getByRole('button', { name: 'Войти', exact: true }).click();
    await guest.locator('#screen-online-lobby.active').waitFor();

    await host.getByText('CI Guest', { exact: true }).waitFor();
    await guest.getByText(/CI Host/).waitFor();

    // Anonymous clients must use the checked RPCs, not read backing tables directly.
    const directTableAccess = await guest.evaluate(async () => {
      const results = await Promise.all([
        supabaseClient.from('rooms').select('id').limit(1),
        supabaseClient.from('room_players').select('player_id').limit(1)
      ]);
      return results.map(result => ({
        allowed: !result.error,
        error: result.error?.message || '',
        code: result.error?.code || ''
      }));
    });
    if (directTableAccess.some(result => result.allowed)) {
      throw new Error('Anonymous client can read a backing table directly: ' + JSON.stringify(directTableAccess));
    }

    // A visible player ID must not let another browser impersonate that player.
    const wrongTokenRead = await guest.evaluate(async () => {
      const { data, error } = await supabaseClient.rpc('get_room_state', {
        p_room_id: online.roomId,
        p_player_id: online.playerId,
        p_player_token: 'invalid-token-for-security-test-000000'
      });
      return { hasData: !!data, error: error?.message || '' };
    });
    if (wrongTokenRead.hasData || !/PLAYER_NOT_AUTHORIZED/.test(wrongTokenRead.error)) {
      throw new Error('Server accepted room-state access with an invalid player token: ' + JSON.stringify(wrongTokenRead));
    }

    const hostImpersonation = await guest.evaluate(async () => {
      const { data, error } = await supabaseClient.rpc('join_room', {
        p_code: online.code,
        p_player_id: online.hostId,
        p_player_token: 'invalid-token-for-security-test-000000',
        p_name: 'Impersonator'
      });
      return { hasData: !!data, error: error?.message || '' };
    });
    if (hostImpersonation.hasData || !/PLAYER_NOT_AUTHORIZED/.test(hostImpersonation.error)) {
      throw new Error('Server accepted an attempt to impersonate the room host: ' + JSON.stringify(hostImpersonation));
    }
    const wrongTokenUpdate = await guest.evaluate(async () => {
      const { data, error } = await supabaseClient.rpc('update_room_state', {
        p_room_id: online.roomId,
        p_player_id: online.playerId,
        p_player_token: 'invalid-token-for-security-test-000000',
        p_expected_version: 0,
        p_game_state: {}
      });
      return { hasData: !!data, error: error?.message || '' };
    });
    if (wrongTokenUpdate.hasData || !/PLAYER_NOT_AUTHORIZED/.test(wrongTokenUpdate.error)) {
      throw new Error('Server accepted a room-state update with an invalid player token: ' + JSON.stringify(wrongTokenUpdate));
    }

    const wrongTokenLeave = await guest.evaluate(async () => {
      const { data, error } = await supabaseClient.rpc('leave_room', {
        p_room_id: online.roomId,
        p_player_id: online.playerId,
        p_player_token: 'invalid-token-for-security-test-000000'
      });
      return { hasData: !!data, error: error?.message || '' };
    });
    if (wrongTokenLeave.hasData || !/PLAYER_NOT_AUTHORIZED/.test(wrongTokenLeave.error)) {
      throw new Error('Server accepted leaving a room with an invalid player token: ' + JSON.stringify(wrongTokenLeave));
    }

    const malformedInitialState = await guest.evaluate(async () => {
      const { data, error } = await supabaseClient.rpc('create_room', {
        p_code: String(Math.floor(10000 + Math.random() * 90000)),
        p_player_id: crypto.randomUUID(),
        p_player_token: 'valid-looking-token-for-security-test-000000',
        p_name: 'Malformed',
        p_game_state: { status: 'lobby', players: [] }
      });
      return { hasData: !!data, error: error?.message || '' };
    });
    if (malformedInitialState.hasData || !/INVALID_GAME_STATE/.test(malformedInitialState.error)) {
      throw new Error('Server accepted malformed initial room state: ' + JSON.stringify(malformedInitialState));
    }

    const missingPlayersInitialState = await guest.evaluate(async () => {
      const { data, error } = await supabaseClient.rpc('create_room', {
        p_code: String(Math.floor(10000 + Math.random() * 90000)),
        p_player_id: crypto.randomUUID(),
        p_player_token: 'valid-looking-token-for-security-test-000000',
        p_name: 'Missing players',
        p_game_state: { status: 'lobby' }
      });
      return { hasData: !!data, error: error?.message || '' };
    });
    if (missingPlayersInitialState.hasData || !/INVALID_GAME_STATE/.test(missingPlayersInitialState.error)) {
      throw new Error('Server accepted initial room state without players: ' + JSON.stringify(missingPlayersInitialState));
    }

    const oversizedInitialState = await guest.evaluate(async () => {
      const { data, error } = await supabaseClient.rpc('create_room', {
        p_code: String(Math.floor(10000 + Math.random() * 90000)),
        p_player_id: crypto.randomUUID(),
        p_player_token: 'valid-looking-token-for-security-test-000000',
        p_name: 'Oversized',
        p_game_state: {
          status: 'lobby',
          players: [{ id: 'oversized-test-player', name: 'Test', score: 0 }],
          padding: 'x'.repeat(201000)
        }
      });
      return { hasData: !!data, error: error?.message || '' };
    });
    if (oversizedInitialState.hasData || !/INVALID_GAME_STATE/.test(oversizedInitialState.error)) {
      throw new Error('Server accepted oversized initial room state: ' + JSON.stringify(oversizedInitialState));
    }

    // Invalid room updates must be rejected without changing persisted state.
    const invalidPayloadUpdate = await host.evaluate(async () => {
      const latest = await supabaseClient.rpc('get_room_state', {
        p_room_id: online.roomId,
        p_player_id: online.playerId,
        p_player_token: online.playerToken
      });
      if (latest.error || !latest.data) return { hasData: false, error: latest.error?.message || 'ROOM_NOT_FOUND' };
      const { data, error } = await supabaseClient.rpc('update_room_state', {
        p_room_id: online.roomId,
        p_player_id: online.playerId,
        p_player_token: online.playerToken,
        p_expected_version: latest.data.version,
        p_game_state: null
      });
      return { hasData: !!data, error: error?.message || '' };
    });
    if (invalidPayloadUpdate.hasData || !/INVALID_GAME_STATE/.test(invalidPayloadUpdate.error)) {
      throw new Error('Server accepted a null game state: ' + JSON.stringify(invalidPayloadUpdate));
    }

    // A valid token must not allow a client to add fake participants to the persisted game state.
    const fakeMemberUpdate = await host.evaluate(async () => {
      const latest = await supabaseClient.rpc('get_room_state', {
        p_room_id: online.roomId,
        p_player_id: online.playerId,
        p_player_token: online.playerToken
      });
      if (latest.error || !latest.data) {
        return { accepted: false, error: latest.error?.message || 'ROOM_NOT_FOUND' };
      }
      const state = latest.data.game_state || {};
      const players = Array.isArray(state.players) ? state.players : [];
      const forgedPlayers = players.map((player, index) =>
        index === players.length - 1
          ? { id: 'forged-nonmember', name: 'Fake player', score: 0 }
          : player
      );
      const { data, error } = await supabaseClient.rpc('update_room_state', {
        p_room_id: online.roomId,
        p_player_id: online.playerId,
        p_player_token: online.playerToken,
        p_expected_version: latest.data.version,
        p_game_state: { ...state, players: forgedPlayers }
      });
      return { accepted: !!data, error: error?.message || '' };
    });
    if (fakeMemberUpdate.accepted || !/INVALID_GAME_STATE/.test(fakeMemberUpdate.error)) {
      throw new Error('Server accepted a fake participant in room state: ' + JSON.stringify(fakeMemberUpdate));
    }

    const invalidStateShapes = await host.evaluate(async () => {
      const cases = [
        { label: 'missing players', state: { status: 'lobby' } },
        {
          label: 'more than 20 players',
          state: {
            status: 'lobby',
            players: [
              { id: online.hostId, name: 'Host', score: 0 },
              ...Array.from({ length: 20 }, (_, i) => ({
                id: 'over-limit-' + i + '-' + crypto.randomUUID(),
                name: 'Player ' + i,
                score: 0
              }))
            ]
          }
        },
        {
          label: 'duplicate player ids',
          state: {
            status: 'lobby',
            players: [
              { id: online.hostId, name: 'Host', score: 0 },
              { id: online.hostId, name: 'Duplicate', score: 0 }
            ]
          }
        }
      ];
      const failures = [];
      for (const item of cases) {
        const latest = await supabaseClient.rpc('get_room_state', {
          p_room_id: online.roomId,
          p_player_id: online.playerId,
          p_player_token: online.playerToken
        });
        if (latest.error || !latest.data) {
          failures.push(item.label + ': could not read current room');
          continue;
        }
        const result = await supabaseClient.rpc('update_room_state', {
          p_room_id: online.roomId,
          p_player_id: online.playerId,
          p_player_token: online.playerToken,
          p_expected_version: latest.data.version,
          p_game_state: item.state
        });
        if (result.data || !/INVALID_GAME_STATE/.test(result.error?.message || '')) {
          failures.push(item.label + ': ' + JSON.stringify({ hasData: !!result.data, error: result.error?.message }));
        }
      }
      return { ok: failures.length === 0, failures };
    });
    if (!invalidStateShapes.ok) throw new Error('Server accepted an invalid room state shape: ' + JSON.stringify(invalidStateShapes));

    // Room should remain alive after authenticated activity.
    const activityTouch = await host.evaluate(async () => {
      const { data, error } = await supabaseClient.rpc('get_room_state', {
        p_room_id: online.roomId,
        p_player_id: online.playerId,
        p_player_token: online.playerToken
      });
      return { hasData: !!data, error: error?.message || '', lastActivityAt: data?.last_activity_at || null };
    });
    if (!activityTouch.hasData || activityTouch.error || !activityTouch.lastActivityAt) {
      throw new Error('Authenticated room activity lookup failed: ' + JSON.stringify(activityTouch));
    }

    const start = host.locator('#online-start-btn');
    await start.waitFor({ state: 'visible' });
    await start.click();

    await host.locator('#screen-online-pass.active').waitFor();
    await guest.locator('#screen-online-pass.active').waitFor();
    await assertNoHorizontalOverflow(host, 'pass screen');
    await host.locator('#online-show-word-btn').click();
    await host.locator('#screen-online-word.active').waitFor();
    await guest.locator('#screen-online-word.active').waitFor();
    await assertNoHorizontalOverflow(host, 'word screen');
    await guest.waitForFunction(() => document.querySelector('#screen-online-word.active #online-the-word')?.textContent.trim() === '???');
    const word = (await host.locator('#online-the-word').innerText()).trim();
    if (!word || word === '???') throw new Error('Host did not receive a real word');

    await host.locator('#screen-online-word .btn-primary').click();
    await host.locator('#screen-online-guess.active').waitFor();
    await assertNoHorizontalOverflow(host, 'guess screen');
    // Only the current explainer sees the guess buttons; the other player sees the pass screen.
    await guest.locator('#screen-online-pass.active').waitFor();
    await host.getByRole('button', { name: 'CI Guest', exact: true }).click();
    await host.locator('#screen-online-result.active').waitFor();
    await guest.locator('#screen-online-result.active').waitFor();
    await assertNoHorizontalOverflow(host, 'result screen');
    await host.getByRole('button', { name: 'Следующий ход' }).click();
    await host.locator('#screen-online-pass.active').waitFor();
    await guest.locator('#screen-online-pass.active').waitFor();
    await host.waitForFunction(() => {
      const scores = document.querySelector('#online-pass-scores')?.innerText || '';
      return /CI Host:\s*1/.test(scores) && /CI Guest:\s*1/.test(scores);
    });
    await guest.waitForFunction(() => {
      const scores = document.querySelector('#online-pass-scores')?.innerText || '';
      return /CI Host:\s*1/.test(scores) && /CI Guest:\s*1/.test(scores);
    });

    // Finish the game, start a rematch, and confirm scores reset on both clients.
    await host.locator('.online-finish-inline:visible').first().click();
    await host.locator('#screen-online-finish.active').waitFor();
    await guest.locator('#screen-online-finish.active').waitFor();
    await assertNoHorizontalOverflow(host, 'finish screen');
    await host.locator('#online-rematch-btn').click();
    await host.locator('#screen-online-pass.active').waitFor();
    await guest.locator('#screen-online-pass.active').waitFor();
    for (const page of [host, guest]) {
      await page.waitForFunction(() => {
        const scores = document.querySelector('#online-pass-scores')?.innerText || '';
        return /CI Host:\s*0/.test(scores) && /CI Guest:\s*0/.test(scores);
      });
    }

    // Reload the guest tab and ensure its saved session returns to the same live room.
    await guest.reload({ waitUntil: 'domcontentloaded' });
    await guest.locator('#screen-online-pass.active').waitFor();
    await guest.waitForFunction(() => {
      const scores = document.querySelector('#online-pass-scores')?.innerText || '';
      return /CI Host:\s*0/.test(scores) && /CI Guest:\s*0/.test(scores);
    });

    // Reload the host tab too; its credentials and host privileges must be restored.
    await host.reload({ waitUntil: 'domcontentloaded' });
    await host.locator('#screen-online-pass.active').waitFor();
    await host.waitForFunction(() => {
      const scores = document.querySelector('#online-pass-scores')?.innerText || '';
      return /CI Host:\s*0/.test(scores) && /CI Guest:\s*0/.test(scores);
    });
    await host.locator('#online-start-btn').waitFor({ state: 'visible' });

    // A player leaving from the UI should disappear from the remaining player's room state.
    await guest.locator('#online-hud-leave').click();
    await guest.locator('#screen-home.active').waitFor();
    await host.waitForFunction(() => {
      const names = document.querySelector('#online-pass-scores')?.innerText || '';
      return /CI Host:\s*0/.test(names) && !/CI Guest/.test(names);
    });
    console.log('PASS: host and guest sessions survive reload; leaving from the guest UI removes that participant.');

    // Verify the server enforces the 20-player limit and removes the test room afterward.
    const capacityResult = await host.evaluate(async () => {
      const hostId = 'capacity-host-' + crypto.randomUUID();
      const hostToken = crypto.randomUUID() + crypto.randomUUID();
      const code = String(Math.floor(10000 + Math.random() * 90000));
      const players = [{ id: hostId, name: 'Capacity Host', score: 0 }];
      const created = await supabaseClient.rpc('create_room', {
        p_code: code,
        p_player_id: hostId,
        p_player_token: hostToken,
        p_name: 'Capacity Host',
        p_game_state: { status: 'lobby', players }
      });
      if (created.error || !created.data) {
        return { ok: false, stage: 'create', error: created.error?.message || 'no room returned' };
      }
      const roomId = created.data.id;
      const joined = [{ id: hostId, token: hostToken }];
      let failure = null;
      try {
        for (let i = 1; i <= 18; i++) {
          const id = 'capacity-player-' + i + '-' + crypto.randomUUID();
          const token = crypto.randomUUID() + crypto.randomUUID();
          const result = await supabaseClient.rpc('join_room', {
            p_code: code,
            p_player_id: id,
            p_player_token: token,
            p_name: 'Capacity ' + i
          });
          if (result.error || !result.data) throw new Error('join player ' + i + ': ' + (result.error?.message || 'no room returned'));
          joined.push({ id, token });
        }
        // Race two players for the final slot: exactly one should join successfully.
        const candidates = [1, 2].map(i => ({
          id: 'capacity-race-' + i + '-' + crypto.randomUUID(),
          token: crypto.randomUUID() + crypto.randomUUID()
        }));
        const raceResults = await Promise.all(candidates.map(player =>
          supabaseClient.rpc('join_room', {
            p_code: code,
            p_player_id: player.id,
            p_player_token: player.token,
            p_name: 'Race player'
          })
        ));
        const accepted = raceResults.filter(result => !!result.data && !result.error).length;
        const rejected = raceResults.filter(result => !result.data && /ROOM_FULL/.test(result.error?.message || '')).length;
        if (accepted !== 1 || rejected !== 1) {
          throw new Error('Concurrent final-slot join was not serialized: ' + JSON.stringify(
            raceResults.map(result => ({ accepted: !!result.data, error: result.error?.message || '' }))
          ));
        }
        raceResults.forEach((result, index) => {
          if (result.data && !result.error) joined.push(candidates[index]);
        });
        const fullId = 'capacity-player-21-' + crypto.randomUUID();
        const full = await supabaseClient.rpc('join_room', {
          p_code: code,
          p_player_id: fullId,
          p_player_token: crypto.randomUUID() + crypto.randomUUID(),
          p_name: 'Should be rejected'
        });
        if (full.data || !/ROOM_FULL/.test(full.error?.message || '')) {
          throw new Error('21st player was not rejected: ' + JSON.stringify({ data: full.data, error: full.error?.message }));
        }
      } catch (e) {
        failure = e.message || String(e);
      } finally {
        for (const player of joined.slice(1).reverse()) {
          await supabaseClient.rpc('leave_room', {
            p_room_id: roomId, p_player_id: player.id, p_player_token: player.token
          });
        }
        await supabaseClient.rpc('leave_room', {
          p_room_id: roomId, p_player_id: hostId, p_player_token: hostToken
        });
      }
      return { ok: !failure, error: failure, roomCode: code, acceptedPlayers: joined.length };
    });
    if (!capacityResult.ok) throw new Error('Room capacity check failed: ' + JSON.stringify(capacityResult));
    console.log('PASS: room capacity is capped at 20 players; a 21st player is rejected and the test room is cleaned up.');

    const lifecycleResult = await host.evaluate(async () => {
      const hostId = 'lifecycle-host-' + crypto.randomUUID();
      const hostToken = crypto.randomUUID() + crypto.randomUUID();
      const guestId = 'lifecycle-guest-' + crypto.randomUUID();
      const guestToken = crypto.randomUUID() + crypto.randomUUID();
      const code = String(Math.floor(10000 + Math.random() * 90000));
      let roomId = null;
      let guestJoined = false;
      let hostLeft = false;
      let failure = null;
      try {
        const created = await supabaseClient.rpc('create_room', {
          p_code: code,
          p_player_id: hostId,
          p_player_token: hostToken,
          p_name: 'Lifecycle Host',
          p_game_state: { status: 'lobby', players: [{ id: hostId, name: 'Lifecycle Host', score: 0 }] }
        });
        if (created.error || !created.data) throw new Error('create: ' + (created.error?.message || 'no room returned'));
        roomId = created.data.id;
        const joined = await supabaseClient.rpc('join_room', {
          p_code: code, p_player_id: guestId, p_player_token: guestToken, p_name: 'Lifecycle Guest'
        });
        if (joined.error || !joined.data) throw new Error('join: ' + (joined.error?.message || 'no room returned'));
        guestJoined = true;

        const stale = await supabaseClient.rpc('update_room_state', {
          p_room_id: roomId,
          p_player_id: hostId,
          p_player_token: hostToken,
          p_expected_version: 0,
          p_game_state: { status: 'lobby', players: [
            { id: hostId, name: 'Lifecycle Host', score: 0 },
            { id: guestId, name: 'Lifecycle Guest', score: 0 }
          ] }
        });
        if (stale.data || !/VERSION_CONFLICT/.test(stale.error?.message || '')) {
          throw new Error('stale update was not rejected: ' + JSON.stringify({ data: stale.data, error: stale.error?.message }));
        }

        const left = await supabaseClient.rpc('leave_room', {
          p_room_id: roomId, p_player_id: hostId, p_player_token: hostToken
        });
        if (left.error || left.data !== true) throw new Error('host leave failed: ' + (left.error?.message || 'unexpected response'));
        hostLeft = true;

        const state = await supabaseClient.rpc('get_room_state', {
          p_room_id: roomId, p_player_id: guestId, p_player_token: guestToken
        });
        if (state.error || !state.data || state.data.host_id !== guestId ||
            state.data.game_state?.players?.length !== 1 ||
            state.data.game_state.players[0]?.id !== guestId) {
          throw new Error('host promotion failed: ' + JSON.stringify({
            error: state.error?.message, hostId: state.data?.host_id, players: state.data?.game_state?.players
          }));
        }
      } catch (e) {
        failure = e.message || String(e);
      } finally {
        if (roomId && guestJoined) {
          await supabaseClient.rpc('leave_room', {
            p_room_id: roomId, p_player_id: guestId, p_player_token: guestToken
          });
        }
        if (roomId && !hostLeft) {
          await supabaseClient.rpc('leave_room', {
            p_room_id: roomId, p_player_id: hostId, p_player_token: hostToken
          });
        }
      }
      return { ok: !failure, error: failure, roomCode: code };
    });
    if (!lifecycleResult.ok) throw new Error('Room lifecycle check failed: ' + JSON.stringify(lifecycleResult));
    console.log('PASS: stale updates are rejected and host departure promotes the next player.');


    // Regression-check the offline flow on the same mobile-sized browser.
    if (await host.locator('#online-hud-leave').isVisible()) {
      await host.locator('#online-hud-leave').click();
      await host.locator('#screen-home.active').waitFor();
    }
    await host.setViewportSize({ width: 320, height: 740 });
    await assertNoHorizontalOverflow(host, 'home at 320px');
    await host.getByRole('button', { name: 'Играть офлайн' }).click();
    await host.locator('#screen-offline-setup.active').waitFor();
    await assertNoHorizontalOverflow(host, 'offline setup at 320px');
    await host.locator('#player-input').fill('Offline Host');
    await host.getByRole('button', { name: /Добавить игрока/ }).click();
    await host.locator('#player-input').fill('Offline Guest');
    await host.getByRole('button', { name: /Добавить игрока/ }).click();
    await host.locator('#start-btn').click();
    await host.locator('#screen-pass.active').waitFor();
    await assertNoHorizontalOverflow(host, 'offline pass at 320px');
    await host.getByRole('button', { name: 'Погнали 🎲' }).click();
    await host.locator('#screen-word.active').waitFor();
    await assertNoHorizontalOverflow(host, 'offline word at 320px');
    const offlineWord = (await host.locator('#the-word').innerText()).trim();
    const offlineLetter = (await host.locator('#the-letter').innerText()).trim();
    if (!offlineWord || !offlineLetter || await host.locator('#reaction-hints .reaction-hint').count() < 1) {
      throw new Error('Offline game did not render a word, letter, and reaction hints');
    }
    await host.getByRole('button', { name: 'Угадали ✅' }).click();
    await host.locator('#screen-guess.active').waitFor();
    await assertNoHorizontalOverflow(host, 'offline guess at 320px');
    await host.getByRole('button', { name: 'Offline Guest', exact: true }).click();
    await host.locator('#screen-pass.active').waitFor();
    const offlineScores = await host.locator('#pass-scores').innerText();
    if (!/Offline Host:\s*1/.test(offlineScores) || !/Offline Guest:\s*1/.test(offlineScores)) {
      throw new Error('Offline score update failed: ' + offlineScores);
    }
    await host.reload({ waitUntil: 'domcontentloaded' });
    await host.locator('#screen-pass.active').waitFor();
    await assertNoHorizontalOverflow(host, 'restored offline pass at 320px');
    const restoredOfflineScores = await host.locator('#pass-scores').innerText();
    if (!/Offline Host:\s*1/.test(restoredOfflineScores) || !/Offline Guest:\s*1/.test(restoredOfflineScores)) {
      throw new Error('Offline session did not restore scores after reload: ' + restoredOfflineScores);
    }
    console.log('PASS: offline word/letter/hints, scoring, and reload restoration work on mobile.');

    if (dialogs.length) throw new Error('Unexpected browser dialogs/errors: ' + dialogs.join(' | '));
    console.log('PASS: two browsers synced the lobby, word and scores; finishing/rematch reset scores, and a guest page reload restored the same room.');
  } finally {
    await cleanup(guest);
    await cleanup(host);
    await guestContext.close();
    await hostContext.close();
    await browser.close();
  }
})().catch(error => {
  console.error(error);
  process.exit(1);
});
