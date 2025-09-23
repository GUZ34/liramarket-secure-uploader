// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Interfaz para el token Lira, para que este contrato sepa cómo llamarlo.
interface ILiraToken {
    function mintReward(address to, uint256 amount) external;
}

// Interfaz mínima para el token USDT (BEP20).
interface IBEP20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

contract MercadoDigital {
    // --- VARIABLES DE ESTADO ---
    address public immutable usdtToken;
    address public admin; // <-- CAMBIO: Se quita "immutable" para poder asignarlo
    address public immutable billeteraComisiones; 
    ILiraToken public liraToken;

    uint256 public constant porcentajeComision = 50; // 0.5% (se representa como 50 en base 10000)
    uint256 public saldoComisionesAcumuladas; 
    uint256 public nextProductId;
    
    uint256 public liraDistribuido;

    enum EstadoProducto { Pendiente, Aprobado, Rechazado }

    struct Producto {
        uint256 id;
        string nombre;
        uint256 precioUSDT;
        address payable vendedor;
        string cidIpfs;
        string cidImagenIpfs;
        uint8 descuentoLira;
        EstadoProducto estado;
    }

    mapping(uint256 => Producto) public productos;
    Producto[] public todosLosProductos;

    // --- MODIFICADORES ---
    modifier onlyAdmin() {
        require(msg.sender == admin, "Solo el admin puede llamar a esta funcion");
        _;
    }
    
    // --- EVENTOS ---
    event ProductoListado(uint256 indexed id, string nombre, address indexed vendedor);
    event ProductoAprobado(uint256 indexed id);
    event ProductoRechazado(uint256 indexed id);
    event ProductoComprado(uint256 indexed id, address indexed comprador, address indexed vendedor, uint256 precio);
    event ComisionesRetiradas(address indexed a, uint256 monto);

    // --- CONSTRUCTOR ---
    constructor(address _usdtToken, address _billeteraComisiones) {
        usdtToken = _usdtToken;
        admin = msg.sender; // <-- CORRECCIÓN: Se mantiene msg.sender para simplicidad, el error era de Remix.
        billeteraComisiones = _billeteraComisiones;
        nextProductId = 1;
    }

    // --- FUNCIONES DE CONFIGURACIÓN ---
    function setLiraTokenAddress(address _liraTokenAddress) public onlyAdmin {
        liraToken = ILiraToken(_liraTokenAddress);
    }
    
    // --- FUNCIONES PÚBLICAS ---
    function listarProducto(
        string memory _nombre,
        uint256 _precio,
        string memory _cidIpfs,
        string memory _cidImagenIpfs,
        uint8 _descuentoLira
    ) public {
        require(bytes(_nombre).length > 0, "El nombre no puede estar vacio");
        require(_precio > 0, "El precio debe ser mayor a cero");
        require(_descuentoLira <= 100, "El descuento no puede ser mayor a 100");

        Producto memory nuevoProducto = Producto(
            nextProductId,
            _nombre,
            _precio,
            payable(msg.sender),
            _cidIpfs,
            _cidImagenIpfs,
            _descuentoLira,
            EstadoProducto.Pendiente
        );
        
        productos[nextProductId] = nuevoProducto;
        todosLosProductos.push(nuevoProducto);
        emit ProductoListado(nextProductId, _nombre, msg.sender);
        nextProductId++;
    }

    function comprarProducto(uint256 _id) public {
        Producto storage producto = productos[_id];
        require(producto.id != 0, "El producto no existe");
        require(producto.estado == EstadoProducto.Aprobado, "El producto no esta a la venta");
        
        bool exitoTransferencia = IBEP20(usdtToken).transferFrom(msg.sender, address(this), producto.precioUSDT);
        require(exitoTransferencia, "La transferencia de USDT al contrato fallo");

        uint256 montoComision = (producto.precioUSDT * porcentajeComision) / 10000;
        uint256 montoParaVendedor = producto.precioUSDT - montoComision;

        bool exitoVendedor = IBEP20(usdtToken).transfer(producto.vendedor, montoParaVendedor);
        require(exitoVendedor, "La transferencia al vendedor fallo");

        saldoComisionesAcumuladas += montoComision;

        if (address(liraToken) != address(0)) {
            uint256 recompensaLira = _calcularRecompensaLira(producto.precioUSDT);
            if (recompensaLira > 0) {
                liraToken.mintReward(msg.sender, recompensaLira);
                liraDistribuido += recompensaLira;
            }
        }
        
        emit ProductoComprado(_id, msg.sender, producto.vendedor, producto.precioUSDT);
    }

    // --- FUNCIONES DE MODERACIÓN Y GESTIÓN (Solo Admin) ---
    function retirarComisiones() public onlyAdmin {
        uint256 monto = saldoComisionesAcumuladas;
        require(monto > 0, "No hay comisiones para retirar");
        saldoComisionesAcumuladas = 0;
        bool exito = IBEP20(usdtToken).transfer(billeteraComisiones, monto);
        require(exito, "La transferencia de comisiones fallo");
        emit ComisionesRetiradas(billeteraComisiones, monto);
    }

    function aprobarProducto(uint256 _id) public onlyAdmin {
        require(productos[_id].id != 0, "El producto no existe");
        productos[_id].estado = EstadoProducto.Aprobado;
        for(uint i=0; i < todosLosProductos.length; i++){
            if(todosLosProductos[i].id == _id){
                todosLosProductos[i].estado = EstadoProducto.Aprobado;
                break;
            }
        }
        emit ProductoAprobado(_id);
    }

    function rechazarProducto(uint256 _id) public onlyAdmin {
        require(productos[_id].id != 0, "El producto no existe");
        productos[_id].estado = EstadoProducto.Rechazado;
         for(uint i=0; i < todosLosProductos.length; i++){
            if(todosLosProductos[i].id == _id){
                todosLosProductos[i].estado = EstadoProducto.Rechazado;
                break;
            }
        }
        emit ProductoRechazado(_id);
    }

    // --- FUNCIONES DE VISTA ---
    function obtenerProductosAprobados() public view returns (Producto[] memory) {
        uint256 contador = 0;
        for (uint i = 0; i < todosLosProductos.length; i++) {
            if (todosLosProductos[i].estado == EstadoProducto.Aprobado) {
                contador++;
            }
        }
        
        Producto[] memory productosAprobados = new Producto[](contador);
        uint256 indice = 0;
        for (uint i = 0; i < todosLosProductos.length; i++) {
            if (todosLosProductos[i].estado == EstadoProducto.Aprobado) {
                productosAprobados[indice] = todosLosProductos[i];
                indice++;
            }
        }
        return productosAprobados;
    }

    function obtenerTodosLosProductos() public view returns (Producto[] memory) {
        return todosLosProductos;
    }

    // --- FUNCIONES INTERNAS ---
    function _calcularRecompensaLira(uint256 _precioUSDT) internal view returns (uint256) {
        uint256 MAX_SUPPLY_LIRA = 21_000_000 * 10**18;
        uint256 FASE1_LIMITE = (MAX_SUPPLY_LIRA * 90 / 100) * 25 / 100;
        uint256 FASE2_LIMITE = FASE1_LIMITE + ((MAX_SUPPLY_LIRA * 90 / 100) * 50 / 100);
        
        if (liraDistribuido < FASE1_LIMITE) {
            return (_precioUSDT / 5); 
        }
        if (liraDistribuido < FASE2_LIMITE) {
            return (_precioUSDT / 10);
        }
        if (liraDistribuido < (MAX_SUPPLY_LIRA * 90 / 100)) {
            return (_precioUSDT / 20);
        }
        return 0;
    }
}
