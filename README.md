<img width="726" height="340" alt="stiker" src="https://github.com/user-attachments/assets/eff3e554-0414-4f01-a7c4-2f5afa3b1e96" />

# OX Debug | Free Developer Tool for Entities & Targets

OX Debug is an in-game developer tool built on ox_target and ox_lib. Aim at any ped, vehicle, object or point in the world and instantly inspect it, edit it, copy its data or create targets and objects, without leaving the game.

> **WARNING:** This script has no permission system. Once it is started, every player on the server can use it. Use it only on a test or development server, or when no players are online.

|  | Requirements | Download |
| --- | --- | --- |
| 📌 | ox_lib | [Github](https://github.com/overextended/ox_lib) |
| 📌 | ox_target | [Github](https://github.com/overextended/ox_target) |

## Features

- Separate Ped, Vehicle and Object menus depending on what you aim at, plus Player, Raycast and Target menus
- Live entity highlight with bounding box, rotation axes and info panel (model, hash, net ID, health, plate, distance)
- Copy model name, hash, position as `vec3()` or `vec4()`, rotation and heading
- Bone viewer for peds, vehicles and yourself
- Vehicle tools: color, fuel, fix, engine, door lock, warp inside
- Ped tools: weapon, ragdoll, heal, clear tasks, animation, scenario, kill
- Player tools: heal, godmode, invisibility, teleport, waypoint, fast travel
- Spawn peds, vehicles and objects, move created objects and copy the full create code
- Target creator: Box Zone, Sphere Zone, Local Entity, Model and Global Ped/Vehicle/Object/Player targets, with ready to paste code
- Live camera-relative editor for zones and objects (arrows, E/Q, mouse wheel, G/H, Ctrl for slow, Enter to confirm)
---


## Installation

1. Place the resource in your resources folder.
2. Start `ox_lib` and `ox_target` before it.
3. Add `ensure nv_debug` to your server.cfg.

Everything can be changed in `config.lua`.

---

## Showcase

<table>
  <tr>
    <td><img src="https://github.com/user-attachments/assets/9e020d6b-9185-4cda-9eb7-6116dd6d4aa8" alt="Screenshot_661" /></td>
    <td><img src="https://github.com/user-attachments/assets/315ab282-59d8-479c-ba76-e2e7d0d903dc" alt="Screenshot_663" /></td>
  </tr>
  <tr>
    <td><img src="https://github.com/user-attachments/assets/62177b03-ac83-4837-b97a-afd38f089dae" alt="Screenshot_664" /></td>
    <td><img src="https://github.com/user-attachments/assets/61bd7063-c4ef-45eb-9095-c2d39cd236d7" alt="Screenshot_665" /></td>
  </tr>
  <tr>
    <td><img src="https://github.com/user-attachments/assets/b5de8864-4398-414d-9fea-c3d4fccba00c" alt="Screenshot_666" /></td>
    <td><img src="https://github.com/user-attachments/assets/13264e47-c332-478c-8d36-dd86e4a5d0cf" alt="Screenshot_662" /></td>
  </tr>
</table>