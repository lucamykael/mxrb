package mxrb.sidecar;

import java.util.Locale;

import com.mendix.systemwideinterfaces.core.IDataType;

/** The type of a microflow parameter or result, or one Core.createDataType names. */
public final class MxDataType implements IDataType {
	private final Metadata metadata;
	private final DataTypeEnum type;
	private final String dsl;
	private final String object;
	private final boolean list;

	MxDataType(Metadata metadata, String type, String dsl, String object, boolean list) {
		this.metadata = metadata;
		this.type = kind(type);
		this.dsl = dsl;
		this.object = object;
		this.list = list;
	}

	/**
	 * A type by its DSL name: "String", "Long", "Datetime", an attribute type such
	 * as "DateTime" or "Enum", "#Module.Enumeration", "Module.Entity" or "[Module.Entity]".
	 */
	public static MxDataType parse(Metadata metadata, String name) {
		if (name.startsWith("[") && name.endsWith("]")) {
			String entity = name.substring(1, name.length() - 1);
			return new MxDataType(metadata, "Object", name, entity, true);
		}
		if (name.startsWith("#")) {
			return new MxDataType(metadata, "Enumeration", name, null, false);
		}
		if (name.contains(".")) {
			return new MxDataType(metadata, "Object", name, name, false);
		}
		DataTypeEnum kind = kind(name);
		return new MxDataType(metadata, kind.name(), kind.name(), null, false);
	}

	private static DataTypeEnum kind(String name) {
		switch (name.toLowerCase(Locale.ROOT)) {
		case "datetime":
			return DataTypeEnum.Datetime;
		case "enum":
		case "enumeration":
			return DataTypeEnum.Enumeration;
		case "void":
			return DataTypeEnum.Nothing;
		default:
			for (DataTypeEnum candidate : DataTypeEnum.values()) {
				if (candidate.name().equalsIgnoreCase(name)) {
					return candidate;
				}
			}
			return DataTypeEnum.Unknown;
		}
	}

	@Override
	public DataTypeEnum getType() {
		return type;
	}

	@Override
	public String getObjectType() {
		return object;
	}

	@Override
	public boolean isList() {
		return list;
	}

	@Override
	public boolean isMendixObject() {
		return type == DataTypeEnum.Object;
	}

	@Override
	public boolean isNothing() {
		return type == DataTypeEnum.Nothing;
	}

	@Override
	public String getDSLType() {
		return dsl;
	}

	@Override
	public MxMetaEnumeration getEnumeration() {
		return dsl != null && dsl.startsWith("#") ? metadata.enumeration(dsl.substring(1)) : null;
	}

	@Override
	public String toString() {
		return dsl;
	}
}
