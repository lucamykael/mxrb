package mxrb.sidecar;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.mendix.systemwideinterfaces.core.meta.IMetaEnumValue;
import com.mendix.systemwideinterfaces.core.meta.IMetaEnumeration;

/**
 * An enumeration of the application. A value's caption key is
 * "Module.Enumeration.value", which Core.getInternationalizedString resolves.
 */
public final class MxMetaEnumeration implements IMetaEnumeration {
	private final String name;
	private final Map<String, IMetaEnumValue> values = new LinkedHashMap<>();

	MxMetaEnumeration(String name, List<String> identifiers) {
		this.name = name;
		for (String identifier : identifiers) {
			values.put(identifier, new IMetaEnumValue() {
				@Override
				public IMetaEnumeration getEnumeration() {
					return MxMetaEnumeration.this;
				}

				@Override
				public String getIdentifier() {
					return identifier;
				}

				@Override
				public String getI18NCaptionKey() {
					return name + "." + identifier;
				}

				@Override
				public String getImage() {
					return null;
				}

				@Override
				public String toString() {
					return identifier;
				}
			});
		}
	}

	@Override
	public String getName() {
		return name;
	}

	@Override
	public Map<String, IMetaEnumValue> getEnumValues() {
		return new LinkedHashMap<>(values);
	}

	@Override
	public String toString() {
		return name;
	}
}
