import re, os, sys
src_dir, out_dir = sys.argv[1], sys.argv[2]

HEADER = """import SwiftUI
import AVKit
import AVFoundation
import Foundation
import WebKit
import Security
import Network
import Combine
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import PhotosUI
#if os(macOS)
import AppKit
#endif

"""

app_map = [
 (14,"Core/Theme.swift"),(395,"Core/Models.swift"),(697,"Core/API.swift"),(1360,"Core/Helpers.swift"),
 (1392,"Core/Images.swift"),(1691,"Favorites/Favorites.swift"),(2789,"Settings/Backup.swift"),
 (2960,"Settings/SiteLog.swift"),(3342,"Settings/SettingsView.swift"),(4045,"Core/Router.swift"),
 (4144,"Home/Home.swift"),(5178,"Root/Root.swift"),(5331,"Catalog/Catalog.swift"),(5776,"Detail/Author.swift"),
 (5880,"Detail/Detail.swift"),(6066,"Player/Progress.swift"),(6151,"Player/Kodik.swift"),(6279,"Player/Player.swift"),
 (7028,"Core/Json.swift"),(7154,"Comments/Comments.swift"),(7713,"Profile/Auth.swift"),(8152,"Profile/Friends.swift"),
 (8962,"Profile/ProfileLook.swift"),(9641,"Profile/ProfileView.swift"),(10572,"Novel/Novel.swift"),
 (11006,"Novel/Offline.swift"),(11595,"Novel/NovelDetail.swift"),(11976,"Manga/MangaServices.swift"),
 (12173,"Manga/MangaSupport.swift"),(13337,"Manga/MangaReader.swift"),(13932,"Novel/NovelPaging.swift"),
 (14201,"Novel/NovelReader.swift"),(15268,"Novel/Marks.swift"),(15616,"Detail/Similar.swift"),
 (15875,"Profile/Stats.swift"),(16073,"App/YumeApp.swift"),
]
kino_map = [(6,"Kino/KinoCore.swift"),(741,"Kino/KinoViews.swift"),(2019,"Kino/KinoPlayers.swift")]

def split(fn, mapping):
    L = open(os.path.join(src_dir, fn), encoding="utf-8").read().split("\n")
    cuts = []
    for start, name in mapping:
        i = start - 1
        while i > 0 and (L[i-1].startswith("@") or L[i-1].startswith("///")):
            i -= 1
        cuts.append((i, name))
    cuts.sort()
    # anything before first cut (imports) dropped
    for k, (i, name) in enumerate(cuts):
        j = cuts[k+1][0] if k+1 < len(cuts) else len(L)
        body = L[i:j]
        # top-level private/fileprivate -> internal (files are split)
        body = [re.sub(r"^(private|fileprivate) ", "", l) if re.match(r"^(private|fileprivate) (struct|class|enum|actor|func|let|var|extension|typealias)", l) else l for l in body]
        path = os.path.join(out_dir, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "w", encoding="utf-8").write(HEADER + "\n".join(body).rstrip("\n") + "\n")
        print(f"{name}: {len(body)}")

split("App.swift", app_map)
split("Kino.swift", kino_map)
