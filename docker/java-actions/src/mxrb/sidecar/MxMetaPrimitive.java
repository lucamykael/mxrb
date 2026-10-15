package mxrb.sidecar;

import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.Map;

import com.mendix.systemwideinterfaces.core.meta.IMetaEnumValue;
import com.mendix.systemwideinterfaces.core.meta.IMetaPrimitive;

/** An attribute of an entity of the application's metamodel. */
public final class MxMetaPrimitive implements IMetaPrimitive {
	private final MxMetaObject parent;
	private final String name;
	private final PrimitiveType type;
	private final int length;
	private final boolean virtual;
	private final MxMetaEnumeration enumeration;

	@SuppressWarnings("unchecked")
	MxMetaPrimitive(Metadata metadata, MxMetaObject parent, Map<String, Object> definition) {
		this.parent = parent;
		this.name = (String) definition.get("name");
		this.type = PrimitiveType.valueOf((String) definition.get("type"));
		this.length = ((Long) definition.get("length")).intValue();
		this.virtual = Boolean.TRUE.equals(definition.get("virtual"));
		Map<String, Object> datatype = (Map<String, Object>) definition.get("datatype");
		List<Object> values = (List<Object>) definition.get("enum");
		this.enumeration = values == null ? null
				: metadata.enumeration(((String) datatype.get("dsl")).substring(1), values);
	}

	@Override
	public String getName() {
		return name;
	}

	@Override
	public String getDefaultValue() {
		return null;
	}

	@Override
	public boolean isVirtual() {
		return virtual;
	}

	@Override
	public int getLength() {
		return length;
	}

	@Override
	public MxMetaObject getParent() {
		return parent;
	}

	@Override
	public PrimitiveType getType() {
		return type;
	}

	@Override
	public Collection<IMetaEnumValue> getEnumValues() {
		return enumeration == null ? new ArrayList<>() : new ArrayList<>(enumeration.getEnumValues().values());
	}

	@Override
	public MxMetaEnumeration getEnumeration() {
		return enumeration;
	}

	@Override
	public boolean isDecimal() {
		return type == PrimitiveType.Decimal;
	}

	@Override
	public boolean isNumeric() {
		return type == PrimitiveType.Decimal || type == PrimitiveType.Integer || type == PrimitiveType.Long
				|| type == PrimitiveType.AutoNumber;
	}

	@Override
	public String toString() {
		return name;
	}
}
