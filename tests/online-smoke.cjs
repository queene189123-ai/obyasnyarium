const { chromium } = require('playwright');

const BASE_URL = 'https://queene189123-ai.github.io/obyasnyarium/';
const TIMEOUT = 20000;

(async () => {
  const browser = await chromium.launch({ headless: true });
  const hostContext = await browser.newContext();
  const guestContext = await browser.newContext();
  const host = await hostContext.newPage();
  const guest = await guestContext.newPage();
  const dialogs = [];

  for (const page of [host, guest]) {
    page.setDefaultTimeout(TIMEOUT);
    page.on('dialog', async dialog => {
      const expectedConfirm = dialog.type === 'confirm' &&
        ['Закончить игру и показать итоговые очки всем игрокам?', 'Начать реванш? Счёт всех игроков обнулится.'].includes(dialog.message());
      if (!expectedConfirm) dialogs.push(dialog.type.toUpperCase() + ': ' + dialog.message());
      await dialog.accept();
    });
    page.on('pageerror', error => dialogs.push('PAGE_ERROR: ' + error.message));
  }

  async function enterOnline(page) {
    await page.goto(BASE_URL, { waitUntil: 'domcontentloaded' });
    await page.getByRole('button', { name: 'Играть онлайн' }).click();
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
    const start = host.locator('#online-start-btn');
    await start.waitFor({ state: 'visible' });
    await start.click();

    await host.locator('#screen-online-pass.active').waitFor();
    await guest.locator('#screen-online-pass.active').waitFor();
    await host.locator('#online-show-word-btn').click();
    await host.locator('#screen-online-word.active').waitFor();
    await guest.locator('#screen-online-word.active').waitFor();
    await guest.waitForFunction(() => document.querySelector('#screen-online-word.active #online-the-word')?.textContent.trim() === '???');
    const word = (await host.locator('#online-the-word').innerText()).trim();
    if (!word || word === '???') throw new Error('Host did not receive a real word');

    await host.locator('#screen-online-word .btn-primary').click();
    await host.locator('#screen-online-guess.active').waitFor();
    // Only the current explainer sees the guess buttons; the other player sees the pass screen.
    await guest.locator('#screen-online-pass.active').waitFor();
    await host.getByRole('button', { name: 'CI Guest', exact: true }).click();
    await host.locator('#screen-online-result.active').waitFor();
    await guest.locator('#screen-online-result.active').waitFor();
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
    await host.locator('#online-finish-btn').click();
    await host.locator('#screen-online-finish.active').waitFor();
    await guest.locator('#screen-online-finish.active').waitFor();
    await host.locator('#online-rematch-btn').click();
    await host.locator('#screen-online-pass.active').waitFor();
    await guest.locator('#screen-online-pass.active').waitFor();
    for (const page of [host, guest]) {
      await page.waitForFunction(() => {
        const scores = document.querySelector('#online-pass-scores')?.innerText || '';
        return /CI Host:\\s*0/.test(scores) && /CI Guest:\\s*0/.test(scores);
      });
    }

    // Reload the guest tab and ensure its saved session returns to the same live room.
    await guest.reload({ waitUntil: 'domcontentloaded' });
    await guest.locator('#screen-online-pass.active').waitFor();
    await guest.waitForFunction(() => {
      const scores = document.querySelector('#online-pass-scores')?.innerText || '';
      return /CI Host:\\s*0/.test(scores) && /CI Guest:\\s*0/.test(scores);
    });

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
