# obsidian-vps-installer

Interaktywny instalator **Obsidian Headless + Claude Code** na VPS.

Jeden skrypt, który automatyzuje cały setup opisany w [przewodniku Obsidian Headless na VPS](https://help.obsidian.md/sync). Bez żonglowania 10 komendami i debugowania na siódmym kroku.

## Co instaluje

- **Obsidian Headless** — klient sync Node.js, bez GUI
- **Claude Code** — natywna instalacja (bez npm), z fixem PATH
- Dedykowanego usera `claude` (bez root)
- **Systemd service** `obsidian-sync` z `--continuous`, auto-restart, lock-file cleanup
- Folder `.claude` z Twojego repo (git sparse checkout + symlink)

## Wymagania

- **VPS z Debian/Ubuntu** i dostępem root
- **Node.js 22+** (skrypt sam zainstaluje jeśli brak)
- **Aktywny [Obsidian Sync](https://obsidian.md/sync)** (płatny)
- **GitHub Personal Access Token** (fine-grained, read-only do repo z folderem `.claude`)

## Użycie

### Instalacja

```bash
curl -fsSL https://raw.githubusercontent.com/AIBiz-Automatyzacje/obsidian-vps-installer/main/install.sh | sudo bash
```

Skrypt:
1. Zapyta o **email, nazwę vault'a, PAT, repo, nazwę urządzenia** (wszystko na raz — potem idź po kawę)
2. Zainstaluje paczki systemowe, Node.js 22, `obsidian-headless`
3. Utworzy usera `claude` i zainstaluje Claude Code
4. **Zrobi pauzę** — poprosi Cię o odpalenie `ob login` w drugim terminalu
5. **Druga pauza** — poprosi o `ob sync-setup` z hasłem e2e
6. Ściągnie `.claude` przez sparse checkout i zrobi symlink
7. Utworzy systemd service z `--continuous`
8. Zweryfikuje że wszystko śmiga

### Reset (usunięcie wszystkiego)

```bash
sudo bash install.sh --reset
```

Usuwa usera `claude`, service, vault lokalny i vault-git. Pliki w Obsidian Sync pozostają — to tylko czyszczenie VPS-a.

### Pomoc

```bash
bash install.sh --help
```

## Dlaczego ten skrypt

Ręczna instalacja to **~15 kroków** + rozwiązywanie 6 known issues (lock zombie, 203/EXEC, EACCES, heredoc z `$()`, PATH claude, crash loop bez `--continuous`). Skrypt:

- **Zbiera wszystkie dane na początku** — nie przerywa w połowie żeby o coś pytać
- **Waliduje PAT** zanim zacznie instalować cokolwiek
- **Automatyczny rollback** jeśli coś padnie w trakcie — VPS wraca do stanu sprzed instalacji
- **Tryb `--reset`** do czystego startu od nowa
- **Fix PATH** dla Claude Code (zgodny z instrukcją installera)
- **Flaga `--continuous`** w systemd service od razu (fix dla crash loop)
- **Weryfikacja końcowa** z testem sync'a

## Tryb interaktywny — dlaczego dwie pauzy

`ob login` i `ob sync-setup` są interaktywne i wymagają haseł (konta Obsidian + e2e). Skrypt **celowo nie próbuje automatyzować** tych kroków przez `expect` — to byłoby kruche i wymagałoby dodatkowej zależności.

Zamiast tego: skrypt się zatrzymuje, pokazuje Ci komendę do skopiowania, Ty robisz to w drugim terminalu, wracasz, naciskasz Enter. Proste, niezawodne, bezpieczne.

## Troubleshooting

### Skrypt padł w trakcie
Rollback wykonał się automatycznie. Zobacz co zrobiłeś źle (zły PAT? brak Obsidian Sync?), napraw, odpal ponownie.

### Sync nie działa po instalacji
```bash
systemctl status obsidian-sync
journalctl -u obsidian-sync -f
```

### Chcę zacząć od zera
```bash
sudo bash install.sh --reset
```

## Struktura po instalacji

```
/home/claude/
├── vault/                   # Obsidian Sync
│   ├── .obsidian/
│   └── .claude -> ~/vault-git/.claude
└── vault-git/               # Git sparse checkout
    └── .claude/             # Konfiguracja Claude Code

/etc/systemd/system/
└── obsidian-sync.service    # User=claude, --continuous
```

## Bezpieczeństwo

- **User `claude`** zamiast root (Claude CLI nie działa pod rootem z flagą `--dangerously-skip-permissions`)
- **PAT trzymany tylko w pamięci** podczas instalacji i w URL remote gita (nie w pliku)
- **Hasła Obsidian (konto + e2e) nigdy nie przechodzą przez skrypt** — wpisujesz je bezpośrednio do `ob`

## Licencja

MIT

---

Zbudowane dla [Akademii Automatyzacji](https://www.skool.com/akademia-automatyzacji) 🚀
