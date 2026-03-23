"""
Generate horowod_mbox.png: a ring of 5 glossy Matryoshka dolls of different sizes
and colors, drawing resources from a central 'toy pool' with pipes and valves. This
represents the 'get from pool' and 'put back' mantra of the Matryoshka project.
"""

import math
import random
from PIL import Image, ImageDraw, ImageFilter

OUT = "_logo/horowod_mbox.png"
GOLD_MBOX_PATH = "_logo/gold_mbox.png"

CANVAS = 512
RING_R = 190  # Increased radius for the central pool
N = 5         # number of dolls

# ── colors ───────────────────────────────────────────────────────────────────
COLORS = [
    (218, 68, 83),   # red
    (68, 138, 218),  # blue
    (242, 184, 79),  # yellow
    (84, 181, 106),  # green
    (178, 102, 218), # purple
]

WOOD_LIGHT = (238, 214, 180)
WOOD_DARK = (204, 170, 131)
DARK_BROWN = (85, 52, 31)
BLACK = (40, 40, 40)
GLOW = (255, 220, 80, 80)
WATER_COLOR_LIGHT = (100, 180, 255, 200)
WATER_COLOR_DARK = (60, 120, 200, 220)
PIPE_COLOR = (150, 160, 170)

def draw_central_pool(draw: ImageDraw.Draw, cx: int, cy: int, doll_centers: list) -> None:
    """Draws the central toy pool with pipes, valves, and a leak."""
    pool_radius = 60
    rim_color = (120, 120, 130)
    
    # Pool basin (rim)
    draw.ellipse([cx - pool_radius, cy - pool_radius, cx + pool_radius, cy + pool_radius], fill=None, outline=rim_color, width=10)
    
    # Water
    draw.ellipse([cx - (pool_radius-5), cy - (pool_radius-5), cx + (pool_radius-5), cy + (pool_radius-5)], fill=WATER_COLOR_DARK)
    draw.ellipse([cx - (pool_radius-10), cy - (pool_radius-10), cx + (pool_radius-10), cy + (pool_radius-10)], fill=WATER_COLOR_LIGHT)

    # Pipes and valves connecting to dolls
    for i, (dx, dy) in enumerate(doll_centers):
        angle = math.atan2(dy - cy, dx - cx)
        
        # Pipe
        pipe_start_x = cx + (pool_radius + 5) * math.cos(angle)
        pipe_start_y = cy + (pool_radius + 5) * math.sin(angle)
        pipe_end_x = dx - (60 * math.cos(angle)) # Connect to base of doll
        pipe_end_y = dy - (60 * math.sin(angle))
        draw.line([(pipe_start_x, pipe_start_y), (pipe_end_x, pipe_end_y)], fill=PIPE_COLOR, width=8)
        
        # Valve
        valve_pos_t = 0.6 # 60% along the pipe
        vx = pipe_start_x + (pipe_end_x - pipe_start_x) * valve_pos_t
        vy = pipe_start_y + (pipe_end_y - pipe_start_y) * valve_pos_t
        draw.ellipse([vx-6, vy-6, vx+6, vy+6], fill='red', outline='darkred', width=2)

    # A small leak
    leak_x = cx + pool_radius * 0.8
    leak_y = cy + pool_radius * 0.8
    puddle_color = (100, 180, 255, 100)
    draw.ellipse([leak_x - 15, leak_y - 10, leak_x + 15, leak_y + 10], fill=puddle_color)
    draw.point((leak_x-5, leak_y-3), fill=WATER_COLOR_DARK)
    draw.point((leak_x+2, leak_y+1), fill=WATER_COLOR_DARK)


def draw_star(draw: ImageDraw.Draw, x, y, size, color, outline_color):
    """Draws a 5-pointed star."""
    points = []
    for i in range(5):
        outer_angle = math.pi / 2 + 2 * math.pi * i / 5
        inner_angle = math.pi / 2 + 2 * math.pi * (i + 0.5) / 5
        points.append((x + size * math.cos(outer_angle), y - size * math.sin(outer_angle)))
        points.append((x + size * 0.4 * math.cos(inner_angle), y - size * 0.4 * math.sin(inner_angle)))
    draw.polygon(points, fill=color, outline=outline_color)

def draw_stars_between(draw: ImageDraw.Draw, x1, y1, x2, y2, cx, cy):
    """Draw a path of stars between two points along an arc."""
    num_stars = 3
    for i in range(1, num_stars + 1):
        t = i / (num_stars + 1)
        
        # Arc interpolation
        mid_x, mid_y = (x1 + x2) / 2, (y1 + y2) / 2
        vx, vy = mid_x - cx, mid_y - cy
        dist = math.sqrt(vx**2 + vy**2)
        if dist == 0: continue
        
        push = 35
        arc_mid_x = mid_x + (vx/dist) * push
        arc_mid_y = mid_y + (vy/dist) * push
        
        tx = int((1-t)**2 * x1 + 2*(1-t)*t*arc_mid_x + t**2 * x2)
        ty = int((1-t)**2 * y1 + 2*(1-t)*t*arc_mid_y + t**2 * y2)
        
        draw_star(draw, tx, ty, 5, (255, 230, 80), (200, 180, 60))



def create_shaded_image(size: int, color: tuple, gold_mbox_img: Image.Image) -> Image.Image:
    """Creates a more 3D-looking Matryoshka doll image."""
    h = size
    w = int(size * 0.7)
    
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # --- Body with shading ---
    # Darker base color
    dark_color = (int(color[0]*0.6), int(color[1]*0.6), int(color[2]*0.6))
    draw.ellipse([0, 0, w-1, h-1], fill=dark_color, outline=BLACK, width=2)
    
    # Mid-tone
    mid_color = (int(color[0]*0.8), int(color[1]*0.8), int(color[2]*0.8))
    draw.ellipse([w*0.05, h*0.05, w*0.95, h*0.95], fill=color)

    # --- Very Glossy Effect ---
    # 1. Soft, broad highlight
    highlight = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    h_draw = ImageDraw.Draw(highlight)
    h_draw.ellipse([w*0.15, h*0.05, w*0.7, h*0.55], fill=(255, 255, 255, 110))
    highlight = highlight.filter(ImageFilter.GaussianBlur(radius=h*0.06))
    img.paste(highlight, (0,0), highlight)
    
    # 2. Sharp, bright highlight
    sharp_highlight_w = w * 0.2
    sharp_highlight_h = h * 0.3
    sharp_highlight_x = w * 0.3
    sharp_highlight_y = h * 0.12
    draw.ellipse([sharp_highlight_x, sharp_highlight_y, sharp_highlight_x + sharp_highlight_w, sharp_highlight_y + sharp_highlight_h], fill=(255, 255, 255, 180))

    # 3. Specular dot highlight
    specular_w = w * 0.05
    specular_h = h * 0.1
    specular_x = w * 0.4
    specular_y = h * 0.18
    draw.ellipse([specular_x, specular_y, specular_x + specular_w, specular_y + specular_h], fill=(255, 255, 255, 220))



    # --- Golden Mailbox ---
    if gold_mbox_img:
        mbox_scale = 0.4 # proportion of doll width
        mbox_w = int(w * mbox_scale)
        mbox_h = int(mbox_w * gold_mbox_img.height / gold_mbox_img.width)
        
        mbox_resized = gold_mbox_img.resize((mbox_w, mbox_h), Image.LANCZOS)
        
        mbox_x = (w - mbox_w) // 2
        mbox_y = int(h * 0.5) # Center vertically on the body
        img.paste(mbox_resized, (mbox_x, mbox_y), mbox_resized)


    # --- Face ---
    face_h = int(h * 0.3)
    face_w = int(w * 0.5)
    face_y_center = int(h * 0.25)
    face_x_center = w // 2
    
    draw.ellipse([face_x_center - face_w//2, face_y_center - face_h//2, face_x_center + face_w//2, face_y_center + face_h//2], fill=WOOD_LIGHT, outline=BLACK, width=1)
    
    # Simple dot eyes (smaller and lighter)
    eye_y = face_y_center - int(face_h * 0.1)
    eye_offset_x = face_w // 4
    draw.point((face_x_center - eye_offset_x, eye_y), fill=DARK_BROWN)
    draw.point((face_x_center + eye_offset_x, eye_y), fill=DARK_BROWN)

    # Rosy cheeks
    cheek_color = (255, 100, 100, 150)
    cheek_radius = face_w * 0.15
    cheek_y = face_y_center + int(face_h * 0.1)
    cheek_offset_x = face_w * 0.3
    draw.ellipse([face_x_center - cheek_offset_x - cheek_radius, cheek_y - cheek_radius, face_x_center - cheek_offset_x + cheek_radius, cheek_y + cheek_radius], fill=cheek_color)
    draw.ellipse([face_x_center + cheek_offset_x - cheek_radius, cheek_y - cheek_radius, face_x_center + cheek_offset_x + cheek_radius, cheek_y + cheek_radius], fill=cheek_color)

    # Smiling mouth
    mouth_y = cheek_y
    mouth_offset_x = eye_offset_x * 0.5
    draw.arc([face_x_center - mouth_offset_x, mouth_y - face_h * 0.1, face_x_center + mouth_offset_x, mouth_y + face_h * 0.1], 0, 180, fill=DARK_BROWN, width=1)



    # --- Base ---
    base_h = int(h * 0.1)
    base_y = h - base_h
    draw.rectangle([0, base_y, w, h], fill=WOOD_DARK)
    draw.line([0, base_y, w, base_y], fill=BLACK, width=2)
    
    return img


def main() -> None:
    random.seed(42)

    try:
        gold_mbox = Image.open(GOLD_MBOX_PATH).convert("RGBA")
        # Make white background transparent
        data = gold_mbox.load()
        w, h = gold_mbox.size
        for y in range(h):
            for x in range(w):
                r, g, b, a = data[x, y]
                if r > 230 and g > 230 and b > 230:
                    data[x, y] = (r, g, b, 0)
    except FileNotFoundError:
        gold_mbox = None
        print(f"Warning: Golden mailbox image not found at '{GOLD_MBOX_PATH}'. Proceeding without it.")

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    
    cx, cy = CANVAS // 2, CANVAS // 2

    # 1. Calculate doll positions
    doll_sizes = [110, 95, 80, 70, 60]
    doll_centers = []
    for i in range(N):
        angle_rad = 2 * math.pi * i / N - math.pi / 2
        mx = int(cx + RING_R * math.cos(angle_rad))
        my = int(cy + RING_R * math.sin(angle_rad))
        doll_centers.append((mx, my))

    # 2. Draw the central pool and pipes
    draw_central_pool(draw, cx, cy, doll_centers)

    # 3. Draw the dolls
    for i in range(N):
        mx, my = doll_centers[i]
        doll_img = create_shaded_image(doll_sizes[i], COLORS[i], gold_mbox)

        rotation_angle = random.uniform(-15, 15)
        rotated_doll = doll_img.rotate(rotation_angle, expand=True, resample=Image.BICUBIC)
        
        px = mx - rotated_doll.width // 2
        py = my - rotated_doll.height // 2
        canvas.paste(rotated_doll, (px, py), rotated_doll)

    # 4. Draw stars between dolls to represent message passing
    for i in range(N):
        x1, y1 = doll_centers[i]
        x2, y2 = doll_centers[(i + 1) % N]
        draw_stars_between(draw, x1, y1, x2, y2, cx, cy)

    canvas.save(OUT, "PNG")
    print(f"Saved {OUT}")


if __name__ == "__main__":
    main()