<p align="center">
  <img src="docs/icon.png" width="128" alt="Icône Claude Eyes">
</p>

<h1 align="center">Claude Eyes</h1>

<p align="center">
  Des yeux de robot macOS qui réagissent à chaque session Claude Code.<br>
  <a href="README.md">English</a> · <b>Français</b>
</p>

---

Quand plusieurs sessions Claude Code tournent en même temps, difficile de savoir laquelle réfléchit, laquelle a fini et laquelle t'attend. Claude Eyes donne à chaque session une paire d'yeux de robot, dans l'esprit de Cozmo, Vector ou Emo : ils se concentrent quand Claude écrit du code, regardent autour d'eux quand il lit, deviennent nerveux pendant les tests, sourient quand il a fini et passent à l'orange quand une session a besoin de toi.

![Expressions](docs/expressions.png)

## Fonctionnalités

- **Yeux flottants** : une fenêtre transparente sans bordure, avec un visage par session, son titre et ce que fait Claude en dessous. Elle se déplace à la souris, et un clic sur un visage ouvre le terminal de la session. Fond en verre dépoli en option.
- **Dock** : soit une icône animée qui montre la session la plus importante (la pastille compte les sessions qui t'attendent), soit **une icône par session**, au nom de la session.
- **Barre des menus** : une icône fixe qui liste les sessions, affiche ou masque la fenêtre flottante et ouvre les réglages.
- **Tes noms et tes couleurs** : le titre donné avec `/rename` et la couleur choisie avec `/color` dans Claude Code sont repris automatiquement. Les états calmes prennent la couleur de la session, les alertes gardent la leur (orange pour l'attente, rouge pour une erreur, vert quand c'est fini) et clignotent pour ne jamais passer inaperçues.
- **Sons** : un petit bip de robot quand une session commence à t'attendre ou termine sa réponse (un son triste en cas d'erreur). Le son de chaque session se coupe depuis la barre des menus, un clic droit sur ses yeux ou son icône du Dock.
- **Toutes les sessions** : chaque session est signalée par un hook de Claude Code. Celles qui tournent sans avoir encore déclenché de hook sont repérées dans la liste des processus et affichées endormies.
- **Compatible avec ton terminal** : un clic sur un visage ramène exactement l'onglet de la session dans Ghostty, Terminal, iTerm2 et WezTerm, et met au premier plan n'importe quelle autre app de terminal. Dans Ghostty et iTerm2, la barre de progression de l'onglet suit l'état de Claude : elle ne disparaît plus pendant les longues réflexions, et reste orange tant qu'une session attend ta réponse.
- **Léger** : visages dessinés par la carte graphique, environ 1 % de CPU pour l'app et 0,5 à 2 % par icône du Dock.

![Couleurs des sessions](docs/colors.png)

*Les états calmes prennent la couleur `/color` de la session. La dernière ligne montre une session qui t'attend : elle reste orange et clignote.*

## Fonctionnement

```
Claude Code ── événement ──▶ hooks/claude-state.sh ──▶ ~/.claude/eyes/sessions/<session>.json ──▶ Claude Eyes.app
                                      │
                                      └──▶ barre de progression de l'onglet dans Ghostty et iTerm2 (OSC 9;4)
```

Claude Code lance le hook à chaque événement (message envoyé, outil lancé ou terminé, permission demandée, réponse terminée…). Le hook écrit l'état de la session dans un petit fichier JSON, et l'app surveille ce dossier. Elle traduit l'état, l'outil utilisé et ce que révèle sa sortie (tests en échec, erreurs, grosses modifications) en expression. Le statut en direct de Claude Code lui indique quand une fenêtre de dialogue t'attend et quand tu y as répondu, même si des sous-agents continuent de travailler.

| Expression | Quand |
|---|---|
| Neutre | Session ouverte, rien en cours |
| Attentif | Tu viens d'envoyer un message |
| Réfléchit | Aucun événement depuis quelques secondes |
| Curieux | Lit des fichiers, cherche dans le code ou sur le web |
| Concentré | Écrit du code, lance une commande ou un agent |
| Nerveux | Lance les tests, le linter ou la vérification des types |
| Surpris | Vient d'écrire une grosse modification |
| Content | Réponse terminée, ou tests réussis |
| Attend ta réponse | Demande de permission, question ou plan à valider |
| Triste | Un outil a échoué, ou des tests sont rouges |
| Contrarié | Le mode auto a refusé une action |
| En erreur | La réponse s'est arrêtée sur une erreur d'API |
| Fatigué | Compacte la conversation |
| Endormi | Aucune activité depuis un moment |

## Prérequis

- macOS 14 ou plus récent, sur Apple Silicon
- Xcode ou les Command Line Tools (`swiftc`, `iconutil`, `codesign`)
- [`jq`](https://jqlang.org) (`brew install jq`)
- Claude Code 2.1 ou plus récent
- N'importe quel terminal : voir [Terminaux pris en charge](#terminaux-pris-en-charge) pour ce que chacun apporte

## Installation

```bash
git clone https://github.com/AnselmeSDR/ClaudeEyes.git
cd ClaudeEyes
./build.sh --install     # compile « Claude Eyes.app », la copie dans ~/Applications et la lance
hooks/install.sh         # crée le lien vers le hook et l'enregistre dans ~/.claude/settings.json
```

`hooks/install.sh` sauvegarde tes réglages dans `~/.claude/settings.json.bak-claude-eyes`. Il fait de `~/.claude/hooks/claude-state.sh` un lien vers la copie du dépôt et désactive la barre de progression propre à Claude Code (`terminalProgressBarEnabled: false`), que le hook remplace dans Ghostty et iTerm2.

Les sessions déjà ouvertes apparaissent tout de suite et se réveillent à leur prochain événement. Au premier clic sur un visage, macOS demande l'autorisation de contrôler ton app de terminal.

Pour lancer l'app à l'ouverture de session, ouvre les **Réglages** depuis l'icône de la barre des menus et active **Lancer à l'ouverture de session**.

## Terminaux pris en charge

| Terminal | Clic sur un visage | Barre de progression de l'onglet |
|---|---|---|
| [Ghostty](https://ghostty.org) | Onglet ou split exact | Oui, à partir de la 1.2 |
| iTerm2 | Onglet exact | Oui, à partir de la 3.6.6 |
| Terminal | Onglet exact | Non |
| WezTerm | Panneau exact | Non |
| VS Code, Cursor, Warp, kitty, autres | L'app passe au premier plan | Non |

Le terminal de chaque session est détecté automatiquement, à partir de la chaîne des processus. Pour une session lancée dans tmux, le clic ramène l'app de terminal depuis laquelle elle a été démarrée. La barre de progression n'est envoyée qu'aux terminaux pour lesquels Claude Code l'active lui-même : ailleurs, la même séquence peut s'afficher comme une notification. Elle se désactive dans **Réglages → Terminal**. Dans Ghostty, `progress-style = false` masque toutes les barres, quelle que soit l'app.

## Réglages

Ils s'ouvrent depuis l'icône de la barre des menus (**Réglages…**) :

- **Fenêtre flottante** : affichage, laisser passer les clics, taille, textes sous les yeux, masquage sans session, fond flouté et son assombrissement, position par défaut.
- **Dock** : icône animée ou non, une seule icône pour la session la plus importante ou une icône par session.
- **Comportement** : durée de l'air content après une réponse, délai avant de s'endormir.
- **Sons** : quand une session t'attend, quand elle a fini, quand elle s'arrête sur une erreur, volume.
- **Terminal** : les terminaux détectés pour tes sessions, barre de progression de l'onglet activée ou non.
- **Système** : lancement à l'ouverture de session.
- **Expressions** : une galerie animée de toutes les expressions, avec ce qui les déclenche.

## Fichiers

| Emplacement | Contenu |
|---|---|
| `~/.claude/eyes/sessions/` | Un fichier JSON par session, écrit par le hook |
| `~/.claude/sessions/<pid>.json` | Registre de Claude Code, lu pour les titres `/rename` et pour savoir si la session t'attend |
| `~/.claude/projects/…/<session>.jsonl` | Transcriptions, lues au fil de l'eau pour `/color` |
| `~/Library/Application Support/Claude Eyes/Docks/` | Copies de l'app utilisées pour les icônes par session |
| `com.anselme.claude-eyes` | Préférences (`defaults read com.anselme.claude-eyes`) |

## Développement

```bash
./build.sh                                   # compile dans build/
./build.sh --install                         # compile, installe et relance
"build/Claude Eyes.app/Contents/MacOS/ClaudeEyes" --render-gallery build/gallery.png      # toutes les expressions
"build/Claude Eyes.app/Contents/MacOS/ClaudeEyes" --render-color-tiles build/colors.png   # toutes les couleurs /color
"build/Claude Eyes.app/Contents/MacOS/ClaudeEyes" --render-sounds build/sounds           # tous les sons, en WAV
```

Du Swift compilé avec `swiftc` (AppKit, SwiftUI, Core Animation), sans projet Xcode. L'architecture est décrite dans [CLAUDE.md](CLAUDE.md).

## Désinstallation

```bash
pkill -x ClaudeEyes
rm -rf ~/Applications/"Claude Eyes.app" ~/Library/Application\ Support/Claude\ Eyes ~/.claude/eyes
rm ~/.claude/hooks/claude-state.sh
defaults delete com.anselme.claude-eyes
```

Retire ensuite les entrées `claude-state.sh` de la section `hooks` de `~/.claude/settings.json` (ou restaure `settings.json.bak-claude-eyes`), et remets `terminalProgressBarEnabled` à `true` si tu veux retrouver la barre de progression de Claude Code.

## Licence

[MIT](LICENSE) © 2026 Anselme SDR

Claude Eyes est un projet indépendant, sans lien avec Anthropic, Digital Dream Labs ou Living AI, ni approuvé ou soutenu par eux. Claude et Claude Code sont des marques d'Anthropic, Cozmo et Vector de Digital Dream Labs, Emo de Living AI.
