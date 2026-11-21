# Roadmap: small HTML/CSS guessing game with an escalation point

Mock planner answer for the 2026-11-06 replay (scope-guard-selftest). Two phases: the guessing game itself, then one
escalation point. Nothing else is built: the Flappy Bird and Crossy Road clones and the escape room of that day are out of scope.
Install-specific fields (install id, project, preset, tier, links, budget, comparators) are replaced by the selftest from the
copy's data; the phases, acceptance checks and out-of-scope list are the planner's answer.

```json roadmap
{
 "schema_version": 1,
 "id": "6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b",
 "install_id": "00000000-0000-4000-8000-000000000000",
 "project": "guessing-game",
 "request": {
  "text": "Build a small HTML/CSS guessing game with an escalation point.",
  "digest": "0000000000000000000000000000000000000000000000000000000000000000"
 },
 "tier": "qa-tier",
 "preset": "qa-preset",
 "phases": [
  {
   "id": "p1",
   "title": "Guessing game core",
   "goal": "A page where the player guesses a secret number and gets higher/lower hints.",
   "builds": [
    "guessing",
    "game",
    "guess",
    "number",
    "hint"
   ],
   "depends_on": [],
   "builder_role": "qa-builder-role",
   "qa_tier": "qa-tier",
   "vm": "TBD",
   "acceptance": [
    {
     "id": "a1",
     "action": "load the page with secret 30 and submit the guess 50",
     "observe": "hint text equals the lower hint",
     "threshold": {
      "comparator": "qa-comparator",
      "value": 1
     },
     "owner_confirm": false,
     "probe": null
    },
    {
     "id": "a2",
     "action": "submit the guesses 50, 20, 30 in order",
     "observe": "guess counter shown on the page",
     "threshold": {
      "comparator": "qa-comparator",
      "value": 3
     },
     "owner_confirm": false,
     "probe": null
    }
   ],
   "cards": [
    {
     "id": "c1",
     "title": "guessing game page and hint logic",
     "kind": "web",
     "files": [
      "guess/*"
     ],
     "size": {
      "files": 3,
      "changed_lines": 150,
      "estimate_hours": 2
     },
     "builder": {
      "connection": "qa-connection",
      "model": "qa-model",
      "rung": 0,
      "reason": "small known pattern"
     },
     "checks": [
      "a1",
      "a2"
     ]
    }
   ]
  },
  {
   "id": "p2",
   "title": "Escalation point",
   "goal": "After N wrong guesses the game raises the difficulty once and says so.",
   "builds": [
    "escalation",
    "point",
    "difficulty",
    "guess"
   ],
   "depends_on": [
    "p1"
   ],
   "builder_role": "qa-builder-role",
   "qa_tier": "qa-tier",
   "vm": "TBD",
   "acceptance": [
    {
     "id": "a3",
     "action": "submit 5 wrong guesses",
     "observe": "difficulty level shown after the fifth wrong guess",
     "threshold": {
      "comparator": "qa-comparator",
      "value": 2
     },
     "owner_confirm": false,
     "probe": null
    },
    {
     "id": "a4",
     "action": "play one full round",
     "observe": "the guessing game is fun to play",
     "threshold": null,
     "owner_confirm": true,
     "probe": null
    }
   ],
   "cards": [
    {
     "id": "c2",
     "title": "escalation point after wrong guesses",
     "kind": "web",
     "files": [
      "guess/*"
     ],
     "size": {
      "files": 2,
      "changed_lines": 80,
      "estimate_hours": 1
     },
     "builder": {
      "connection": "qa-connection",
      "model": "qa-model",
      "rung": 0,
      "reason": "small known pattern"
     },
     "checks": [
      "a3",
      "a4"
     ]
    }
   ]
  }
 ],
 "out_of_scope": [
  "Flappy Bird clone",
  "Crossy Road clone",
  "escape room"
 ],
 "estimate": {
  "tokens": 120000,
  "cost": 1,
  "hours": 3,
  "budget_cap": 10
 },
 "assignments": {
  "qa-builder-role": {
   "connection": "qa-connection",
   "model": "qa-model"
  }
 }
}
```
