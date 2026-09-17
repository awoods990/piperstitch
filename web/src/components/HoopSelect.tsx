import { useState } from "react";
import type { CatalogSize } from "../types";
import { hoopGroups } from "../hoops";
import { size } from "../format";

const SHOW_ALL = "__show_all__", EDIT = "__edit__";

/** One <select> of hoops, grouped by line -- used in the toolbar and the
 *  Inspector so both offer exactly the same list the same way. When the
 *  business told guided setup which hoops it owns, only those are listed,
 *  with "Show all hoops" and "Edit my hoops" at the bottom. */
export function HoopSelect({ hoops, value, onChange, withSizes, ownedNames, onEditHoops }: {
  hoops: CatalogSize[]; value: CatalogSize | null; onChange: (h: CatalogSize | null) => void; withSizes?: boolean;
  ownedNames?: string[]; onEditHoops?: () => void;
}) {
  const owned = (ownedNames ?? []).filter((n) => hoops.some((h) => h.name === n));
  // A current hoop outside the owned list (a project from before setup) is always shown.
  const [showAll, setShowAll] = useState(false);
  const limited = owned.length > 0 && !showAll;
  const groups = limited
    ? [["Your hoops", hoops.filter((h) => owned.includes(h.name) || h.name === value?.name)] as [string, CatalogSize[]]]
    : hoopGroups(hoops, owned);
  return (
    <select value={value?.name ?? ""} onChange={(e) => {
      if (e.target.value === SHOW_ALL) { setShowAll(true); return; }
      if (e.target.value === EDIT) { onEditHoops?.(); return; }
      onChange(hoops.find((x) => x.name === e.target.value) ?? null);
    }}>
      <option value="">None (no fit check)</option>
      {groups.map(([group, list]) => (
        <optgroup key={group} label={group}>
          {list.map((x) => (
            <option key={x.name} value={x.name}>
              {x.name.replace(/^(Mighty Hoop|Durkee EZ Frame) /, "")}{withSizes ? ` — ${size(x.widthMM, x.heightMM)}` : ""}
            </option>
          ))}
        </optgroup>
      ))}
      {(limited || onEditHoops) && (
        <optgroup label="—">
          {limited && <option value={SHOW_ALL}>Show all hoops & frames…</option>}
          {onEditHoops && <option value={EDIT}>Edit my hoops…</option>}
        </optgroup>
      )}
    </select>
  );
}
