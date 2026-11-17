# Contribuindo com o BatteryBar

Obrigado pelo interesse. O BatteryBar é pequeno de propósito: um item de
barra de menus em um arquivo de código. Mudança boa é a que deixa o app
mais simples ou mais confiável; feature nova vale conversar numa issue
antes.

## Preparar a máquina

Precisa de macOS 13 ou superior e do Command Line Tools. Não precisa de
Xcode.

```bash
xcode-select --install
git clone https://github.com/vleineker/battery-bar.git
cd battery-bar
```

## Compilar e testar

```bash
./build.sh
build/BatteryBar.app/Contents/MacOS/BatteryBar --list
```

Não há testes automáticos: o app conversa com aparelhos de verdade. O
`--list` imprime a resposta crua de cada aparelho e é a forma de conferir
uma mudança.

## Cuidados

- Nada de dependência nova.
- O app só envia ao mouse consultas de leitura, a definição de DPI e a
  troca de modo do perfil interno. Qualquer outra escrita no aparelho
  precisa de issue antes.
- Suporte a um aparelho novo vem com a saída do `--list` no pull request,
  dizendo o modelo e como ele está conectado.
- A interface é em português do Brasil.

## Mandando uma mudança

1. Abra uma issue descrevendo o problema ou a ideia, se ainda não houver.
2. Crie uma branch a partir da `main`.
3. Commits em inglês, no formato conventional commits (`feat:`, `fix:`,
   `docs:`, `chore:`).
4. Rode `./build.sh` e use o app de verdade antes de abrir o pull request.
5. No pull request, diga o que mudou para quem usa e como você testou.

Ao contribuir, você concorda em licenciar sua contribuição sob a licença
MIT do projeto (`LICENSE`).
